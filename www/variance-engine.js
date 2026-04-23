// ══════════════════════════════════════════════════════════════
// BARINV — POS ↔ Inventory Variance Engine
// Core loss detection system
// Version: 1.0.0
// Date: April 12, 2026
//
// This is the CORE of BARINV.
// It compares what was SOLD (POS) vs what was USED (inventory)
// to detect loss, theft, and suspicious patterns.
// ══════════════════════════════════════════════════════════════

'use strict';

// ──────────────────────────────────────────────
// CONFIGURATION
// ──────────────────────────────────────────────
const VARIANCE_CONFIG = {
  // Alert thresholds (in dollars)
  ALERT_LOW: 50,        // > $50 unexplained loss
  ALERT_MEDIUM: 150,    // > $150 unexplained loss
  ALERT_HIGH: 500,      // > $500 unexplained loss

  // Variance tolerance (percentage) — below this is considered normal
  TOLERANCE_PCT: 5,     // 5% variance is acceptable (spillage, over-pour)

  // Default shot size (ml) if not specified per item
  DEFAULT_SHOT_ML: 30,  // 1oz = ~30ml

  // Density map (g/ml) for weight → volume conversion
  DENSITY: {
    'vodka': 0.95, 'whisky': 0.94, 'whiskey': 0.94, 'bourbon': 0.94,
    'scotch': 0.94, 'irish whiskey': 0.94, 'rum': 0.95, 'gin': 0.94,
    'tequila': 0.94, 'mezcal': 0.94, 'brandy': 0.95, 'cognac': 0.95,
    'brandy / cognac': 0.95, 'herbal / liqueur': 1.00, 'liqueur': 1.00,
    'wine': 0.99, 'champagne': 0.99, 'beer': 1.00, 'sake': 1.00,
    'non-alcoholic': 1.00, 'energy drink / mixer': 1.02
  },

  DEFAULT_DENSITY: 0.94
};


// ──────────────────────────────────────────────
// UNIT CONVERSION — single source of truth
// ──────────────────────────────────────────────
// events.qty stores the number in the item's native unit:
//   unit='case'   → qty = number of cases
//   unit='bottle' → qty = number of bottles
//   unit='can'    → qty = number of cans
//   unit='each'   → qty = number of units
// All variance math runs in bottle-equivalents, so every event read
// MUST go through this helper. Keeping a single function guarantees
// DELIVERED and RETURNED can't drift out of sync — which was the v2.4.2
// loss-overreporting bug (returns were not multiplied by units_per_case
// while dispatch was).
function eventBottles(event, item) {
  const qty = Number(event?.qty || 0);
  if (!item) return qty;
  const isCase = item.unit === 'case';
  const unitsPerCase = isCase ? (Number(item.units_per_case) || 24) : 1;
  return qty * unitsPerCase;
}

// Giveaway actions (COMP, SHOT, PROMO) store qty as shots, not bottles.
// Keep this helper distinct from eventBottles so callers can't confuse the
// two quantity bases.
function giveawayMl(event, item) {
  const qty = Number(event?.qty || 0);
  if (!item || qty <= 0) return 0;
  const density = Number(item.density) || getDensity(item.category) || VARIANCE_CONFIG.DEFAULT_DENSITY;
  const shotMl = item.shot_weight_g ? item.shot_weight_g / density : VARIANCE_CONFIG.DEFAULT_SHOT_ML;
  return qty * shotMl;
}

function giveawaysToMl(events, items) {
  const out = {};
  for (const e of events) {
    if (e.action !== 'COMP' && e.action !== 'SHOT' && e.action !== 'PROMO') continue;
    const item = items.find(i => i.id === e.item_id);
    if (!item) continue;
    if (!out[e.item_id]) out[e.item_id] = { ml: 0, shots: 0, by_action: { COMP: 0, SHOT: 0, PROMO: 0 } };
    const ml = giveawayMl(e, item);
    out[e.item_id].ml += ml;
    out[e.item_id].shots += Number(e.qty || 0);
    out[e.item_id].by_action[e.action] += ml;
  }
  return out;
}

// Classify an item category as alcoholic / non_alcoholic / unknown.
// Unknowns are not guessed — categories not in either allowlist return 'unknown'.
const ALCOHOLIC_CATEGORIES = new Set([
  'vodka','whisky','whiskey','bourbon','scotch','irish whiskey',
  'rum','gin','tequila','mezcal','brandy','cognac',
  'brandy / cognac','cognac (brandy)','herbal / liqueur','liqueur',
  'wine','champagne','beer','sake'
]);
const NON_ALCOHOLIC_CATEGORIES = new Set([
  'non-alcoholic','energy drink / mixer'
]);
function classifyAlcohol(category) {
  if (!category) return 'unknown';
  const c = String(category).toLowerCase().trim();
  if (ALCOHOLIC_CATEGORIES.has(c)) return 'alcoholic';
  if (NON_ALCOHOLIC_CATEGORIES.has(c)) return 'non_alcoholic';
  return 'unknown';
}


// ──────────────────────────────────────────────
// INPUT: POS SALES DATA
// ──────────────────────────────────────────────

/**
 * Process raw POS orders into expected usage per item
 *
 * @param {Array} orders - Raw Square orders array
 * @param {Array} items - BARINV items with bottle_size_ml, category, cost_price, sale_price
 * @param {Object} itemMapping - Maps POS product names → BARINV item IDs
 * @returns {Object} Expected usage per item: { itemId: { name, qty_sold, ml_expected, bottles_expected, revenue } }
 */
function posToExpectedUsage(orders, items, itemMapping) {
  const usage = {};

  for (const order of orders) {
    if (order.state !== 'COMPLETED') continue;

    for (const li of (order.line_items || [])) {
      const posName = li.name || 'Unknown';
      let qty = parseInt(li.quantity || '1');
      const revenue = (li.gross_sales_money?.amount || 0) / 100;

      // Detect pour size from POS name (e.g., "2oz - FINLANDIA" = 2 shots per unit)
      const pourMatch = posName.match(/^(\d+)\s*oz\s/i);
      if (pourMatch) {
        const pourOz = parseInt(pourMatch[1]);
        if (pourOz > 1) qty = qty * pourOz; // 5 × 2oz = 10 shots
      }

      // Map POS product to BARINV item
      const itemId = itemMapping[posName] || itemMapping[posName.toLowerCase()] || null;
      const item = itemId ? items.find(i => i.id === itemId) : null;

      // Try auto-matching by name if no mapping exists
      let matchedItem = item;
      if (!matchedItem) {
        const nameLower = posName.toLowerCase();
        matchedItem = items.find(i => {
          const iName = (i.name || '').toLowerCase();
          return nameLower.includes(iName) || iName.includes(nameLower);
        });
      }

      if (!matchedItem) continue; // Can't match this POS item to inventory

      const id = matchedItem.id;
      const shotMl = matchedItem.shot_weight_g
        ? matchedItem.shot_weight_g / (getDensity(matchedItem.category) || VARIANCE_CONFIG.DEFAULT_DENSITY)
        : VARIANCE_CONFIG.DEFAULT_SHOT_ML;
      const bottleMl = matchedItem.bottle_size_ml || 750;

      if (!usage[id]) {
        usage[id] = {
          itemId: id,
          name: matchedItem.name,
          category: matchedItem.category || '',
          bottle_size_ml: bottleMl,
          cost_price: Number(matchedItem.cost_price || 0),
          sale_price: Number(matchedItem.sale_price || 0),
          shot_ml: shotMl,
          qty_sold: 0,
          ml_expected: 0,
          bottles_expected: 0,
          revenue: 0
        };
      }

      usage[id].qty_sold += qty;
      usage[id].ml_expected += qty * shotMl;
      usage[id].bottles_expected = usage[id].ml_expected / bottleMl;
      usage[id].revenue += revenue;
    }
  }

  return usage;
}


// ──────────────────────────────────────────────
// INPUT: DISPATCH DATA
// ──────────────────────────────────────────────

/**
 * Calculate actual bottles dispatched per item per bar
 *
 * @param {Array} events - BARINV events where action = 'DELIVERED'
 * @param {Array} items - BARINV items array
 * @returns {Object} Dispatched per item: { itemId: { name, bottles_sent, ml_sent, bars: { barId: qty } } }
 */
function dispatchToActualSent(events, items) {
  const sent = {};

  for (const e of events) {
    if (e.action !== 'DELIVERED' && e.action !== 'REQUEST') continue;

    const id = e.item_id;
    if (!id) continue;
    const item = items.find(i => i.id === id);
    if (!item) continue;

    const bottleMl = item.bottle_size_ml || 750;
    const actualBottles = eventBottles(e, item);

    if (!sent[id]) {
      sent[id] = {
        itemId: id,
        name: item.name,
        category: item.category || '',
        bottle_size_ml: bottleMl,
        bottles_sent: 0,
        ml_sent: 0,
        bars: {}
      };
    }

    // Weigh-on-dispatch parity: a partially-used bottle sent OUT carries
    // its measured weight in the notes (`Weigh#N(OUT): NNNg ...`). If we
    // see that marker, convert weight → actual liquid ml and use that
    // instead of assuming a full bottle. Mirror of the weigh-RETURN path
    // in returnsToActualRemaining(). Physical bottle count still += 1.
    const notes = e.notes || '';
    const weighOutMatch = notes.match(/Weigh#\d+\(OUT\):\s*(\d+)g/);
    let mlAdded;
    if (weighOutMatch) {
      const emptyWeight = Number(item.empty_bottle_weight_g || 0);
      const density = Number(item.density) || getDensity(item.category) || VARIANCE_CONFIG.DEFAULT_DENSITY;
      const currentWeight = Number(weighOutMatch[1]);
      const liquidG = Math.max(0, currentWeight - emptyWeight);
      mlAdded = Math.round(liquidG / density);
    } else {
      mlAdded = actualBottles * bottleMl;
    }

    sent[id].bottles_sent += actualBottles;
    sent[id].ml_sent += mlAdded;

    // Track per bar (physical bottle count)
    const barId = e.bar_id || 'unknown';
    sent[id].bars[barId] = (sent[id].bars[barId] || 0) + actualBottles;
  }

  return sent;
}


// ──────────────────────────────────────────────
// INPUT: RETURN DATA (Scale-based)
// ──────────────────────────────────────────────

/**
 * Calculate actual liquid returned per item from weigh data
 *
 * @param {Array} events - BARINV events where action = 'RETURNED'
 * @param {Array} items - BARINV items with empty_bottle_weight_g, density
 * @returns {Object} Returned per item: { itemId: { name, bottles_returned, ml_returned, weigh_data: [] } }
 */
function returnsToActualRemaining(events, items) {
  const returned = {};

  for (const e of events) {
    if (e.action !== 'RETURNED') continue;

    const id = e.item_id;
    if (!id) continue;
    const item = items.find(i => i.id === id);
    if (!item) continue;

    const bottleMl = item.bottle_size_ml || 750;
    const emptyWeight = Number(item.empty_bottle_weight_g || 0);
    const density = Number(item.density) || getDensity(item.category) || VARIANCE_CONFIG.DEFAULT_DENSITY;

    if (!returned[id]) {
      returned[id] = {
        itemId: id,
        name: item.name,
        bottles_returned_full: 0,    // full bottles returned
        bottles_returned_partial: 0,  // partial bottles (weighed)
        ml_returned: 0,
        weigh_data: []
      };
    }

    // Parse weigh data from notes if available
    const notes = e.notes || '';
    const weighMatch = notes.match(/Weigh#\d+:\s*(\d+)g/);

    if (weighMatch && emptyWeight > 0) {
      // Scale-based return — ONE physical bottle weighed. Scale gives
      // us the precise liquid ml of that single bottle regardless of
      // whether the item is tracked as case or bottle.
      const currentWeight = Number(weighMatch[1]);
      const liquidG = Math.max(0, currentWeight - emptyWeight);
      const liquidMl = Math.round(liquidG / density);

      returned[id].ml_returned += liquidMl;
      returned[id].bottles_returned_partial++;
      returned[id].weigh_data.push({
        weight_g: currentWeight,
        empty_g: emptyWeight,
        liquid_ml: liquidMl,
        density
      });
    } else {
      // Full-unit return. MUST use the same conversion as dispatch — a
      // returned case of N bottles is N bottles back, not 1.
      const actualBottles = eventBottles(e, item);
      returned[id].bottles_returned_full += actualBottles;
      returned[id].ml_returned += actualBottles * bottleMl;
    }
  }

  return returned;
}


// ──────────────────────────────────────────────
// CORE: VARIANCE CALCULATION
// ──────────────────────────────────────────────

/**
 * THE CORE ENGINE
 * Compares expected usage (POS) vs actual usage (dispatch - returns)
 * to calculate variance (loss) per item
 *
 * @param {Object} expected - From posToExpectedUsage()
 * @param {Object} dispatched - From dispatchToActualSent()
 * @param {Object} returned - From returnsToActualRemaining()
 * @param {Array} items - BARINV items array
 * @returns {Object} Variance report
 */
function calculateVariance(expected, dispatched, returned, items, giveaways = {}) {
  const results = {
    items: {},
    totals: {
      total_expected_ml: 0,
      total_actual_ml: 0,
      total_variance_ml: 0,
      total_variance_bottles: 0,
      total_variance_dollars: 0,
      total_revenue: 0,
      total_cost: 0,
      items_flagged: 0,
      severity: 'OK'
    },
    alerts: [],
    timestamp: new Date().toISOString()
  };

  // Get all unique item IDs across all four datasets
  const allItemIds = new Set([
    ...Object.keys(expected),
    ...Object.keys(dispatched),
    ...Object.keys(returned),
    ...Object.keys(giveaways)
  ]);

  for (const id of allItemIds) {
    const exp = expected[id] || {};
    const disp = dispatched[id] || {};
    const ret = returned[id] || {};
    const give = giveaways[id] || { ml: 0, shots: 0, by_action: { COMP: 0, SHOT: 0, PROMO: 0 } };
    const item = items.find(i => i.id === id);
    if (!item) continue;

    const bottleMl = item.bottle_size_ml || 750;
    const costPrice = Number(item.cost_price || 0);
    const salePrice = Number(item.sale_price || 0);
    const shotMl = exp.shot_ml || VARIANCE_CONFIG.DEFAULT_SHOT_ML;

    // ── EXPECTED USAGE (what POS says should have been consumed) ──
    const ml_expected = exp.ml_expected || 0;
    const bottles_expected = ml_expected / bottleMl;
    const revenue = exp.revenue || 0;

    // ── ACTUAL UNEXPLAINED USAGE (what inventory says was consumed) ──
    // Giveaways (COMP/SHOT/PROMO) are intentional dispensing and must NOT
    // be counted as unexplained loss. Subtract them from ml_actual so the
    // variance number reflects only unaccounted consumption.
    // WASTE and BREAKAGE are real losses and are NOT subtracted here.
    const ml_sent = disp.ml_sent || 0;
    const ml_returned = ret.ml_returned || 0;
    const ml_giveaway = Number(give.ml || 0);
    const ml_actual = Math.max(0, ml_sent - ml_returned - ml_giveaway);
    const bottles_actual = ml_actual / bottleMl;

    // ── VARIANCE (the difference — positive = loss) ──
    const variance_ml = ml_actual - ml_expected;
    const variance_bottles = variance_ml / bottleMl;
    const variance_shots = variance_ml / shotMl;
    const variance_pct = ml_expected > 0 ? (variance_ml / ml_expected) * 100 : (ml_actual > 0 ? 100 : 0);

    // ── DOLLAR LOSS ──
    // Cost-based: how much product was lost at cost price
    const cost_per_ml = costPrice / bottleMl;
    const variance_cost = variance_ml * cost_per_ml;

    // Revenue-based: how much revenue was lost at sale price
    const revenue_per_shot = salePrice || (revenue / Math.max(1, exp.qty_sold || 1));
    const variance_revenue = variance_shots * revenue_per_shot;

    // ── SEVERITY ──
    let severity = 'OK';
    if (Math.abs(variance_revenue) > VARIANCE_CONFIG.ALERT_HIGH) severity = 'HIGH';
    else if (Math.abs(variance_revenue) > VARIANCE_CONFIG.ALERT_MEDIUM) severity = 'MEDIUM';
    else if (Math.abs(variance_revenue) > VARIANCE_CONFIG.ALERT_LOW) severity = 'LOW';
    else if (Math.abs(variance_pct) > VARIANCE_CONFIG.TOLERANCE_PCT && ml_expected > 0) severity = 'LOW';

    const itemResult = {
      itemId: id,
      name: item.name,
      category: item.category || '',

      // Expected (from POS)
      pos_qty_sold: exp.qty_sold || 0,
      ml_expected: Math.round(ml_expected),
      bottles_expected: Math.round(bottles_expected * 100) / 100,

      // Actual (from inventory)
      bottles_sent: disp.bottles_sent || 0,
      ml_sent: Math.round(ml_sent),
      ml_returned: Math.round(ml_returned),
      ml_giveaway: Math.round(ml_giveaway),
      giveaway_shots: Number(give.shots || 0),
      giveaway_by_action: give.by_action || { COMP: 0, SHOT: 0, PROMO: 0 },
      ml_actual: Math.round(ml_actual),
      bottles_actual: Math.round(bottles_actual * 100) / 100,

      // Variance
      variance_ml: Math.round(variance_ml),
      variance_bottles: Math.round(variance_bottles * 100) / 100,
      variance_shots: Math.round(variance_shots * 10) / 10,
      variance_pct: Math.round(variance_pct * 10) / 10,
      variance_cost: Math.round(variance_cost * 100) / 100,
      variance_revenue: Math.round(variance_revenue * 100) / 100,

      // Meta
      revenue: Math.round(revenue * 100) / 100,
      severity,
      has_weigh_data: (ret.weigh_data || []).length > 0,
      bars_dispatched: disp.bars || {}
    };

    results.items[id] = itemResult;

    // Accumulate totals
    results.totals.total_expected_ml += ml_expected;
    results.totals.total_actual_ml += ml_actual;
    results.totals.total_variance_ml += variance_ml;
    results.totals.total_variance_bottles += variance_bottles;
    results.totals.total_variance_dollars += variance_revenue;
    results.totals.total_revenue += revenue;
    results.totals.total_cost += (bottles_actual * costPrice);

    // Generate alerts for flagged items
    if (severity !== 'OK') {
      results.totals.items_flagged++;
      results.alerts.push({
        itemId: id,
        item_name: item.name,
        severity,
        variance_ml: Math.round(variance_ml),
        variance_shots: Math.round(variance_shots * 10) / 10,
        variance_dollars: Math.round(variance_revenue * 100) / 100,
        variance_pct: Math.round(variance_pct * 10) / 10,
        message: `${item.name}: ${Math.abs(Math.round(variance_shots * 10) / 10)} shots unaccounted ($${Math.abs(Math.round(variance_revenue * 100) / 100)})`
      });
    }
  }

  // Round totals
  results.totals.total_expected_ml = Math.round(results.totals.total_expected_ml);
  results.totals.total_actual_ml = Math.round(results.totals.total_actual_ml);
  results.totals.total_variance_ml = Math.round(results.totals.total_variance_ml);
  results.totals.total_variance_bottles = Math.round(results.totals.total_variance_bottles * 100) / 100;
  results.totals.total_variance_dollars = Math.round(results.totals.total_variance_dollars * 100) / 100;
  results.totals.total_revenue = Math.round(results.totals.total_revenue * 100) / 100;
  results.totals.total_cost = Math.round(results.totals.total_cost * 100) / 100;

  // Overall severity
  const totalLoss = Math.abs(results.totals.total_variance_dollars);
  if (totalLoss > VARIANCE_CONFIG.ALERT_HIGH) results.totals.severity = 'HIGH';
  else if (totalLoss > VARIANCE_CONFIG.ALERT_MEDIUM) results.totals.severity = 'MEDIUM';
  else if (totalLoss > VARIANCE_CONFIG.ALERT_LOW) results.totals.severity = 'LOW';

  // Sort alerts by severity then dollars
  const severityOrder = { HIGH: 0, MEDIUM: 1, LOW: 2 };
  results.alerts.sort((a, b) =>
    (severityOrder[a.severity] || 3) - (severityOrder[b.severity] || 3) ||
    Math.abs(b.variance_dollars) - Math.abs(a.variance_dollars)
  );

  return results;
}


// ──────────────────────────────────────────────
// BAR-LEVEL VARIANCE
// ──────────────────────────────────────────────

/**
 * Calculate variance per bar (requires POS data mapped to bars)
 *
 * @param {Object} varianceResult - From calculateVariance()
 * @param {Array} bars - BARINV bars array
 * @returns {Object} Per-bar variance summary
 */
function variancePerBar(varianceResult, bars) {
  const barResults = {};

  for (const bar of bars) {
    barResults[bar.id] = {
      barId: bar.id,
      barName: bar.name,
      total_dispatched_bottles: 0,
      total_variance_ml: 0,
      total_variance_dollars: 0,
      items: [],
      severity: 'OK'
    };
  }

  // Aggregate item variance into bars based on dispatch data
  for (const [itemId, item] of Object.entries(varianceResult.items)) {
    const barsDispatched = item.bars_dispatched || {};

    for (const [barId, bottlesSent] of Object.entries(barsDispatched)) {
      if (!barResults[barId]) continue;

      // Proportional variance: if bar received 40% of bottles, assume 40% of variance
      const totalSent = item.bottles_sent || 1;
      const proportion = bottlesSent / totalSent;

      barResults[barId].total_dispatched_bottles += bottlesSent;
      barResults[barId].total_variance_ml += item.variance_ml * proportion;
      barResults[barId].total_variance_dollars += item.variance_revenue * proportion;
      barResults[barId].items.push({
        itemId,
        name: item.name,
        bottles_sent: bottlesSent,
        variance_ml: Math.round(item.variance_ml * proportion),
        variance_dollars: Math.round(item.variance_revenue * proportion * 100) / 100
      });
    }
  }

  // Calculate severity per bar
  for (const bar of Object.values(barResults)) {
    bar.total_variance_ml = Math.round(bar.total_variance_ml);
    bar.total_variance_dollars = Math.round(bar.total_variance_dollars * 100) / 100;

    const loss = Math.abs(bar.total_variance_dollars);
    if (loss > VARIANCE_CONFIG.ALERT_HIGH) bar.severity = 'HIGH';
    else if (loss > VARIANCE_CONFIG.ALERT_MEDIUM) bar.severity = 'MEDIUM';
    else if (loss > VARIANCE_CONFIG.ALERT_LOW) bar.severity = 'LOW';
  }

  return barResults;
}


// ──────────────────────────────────────────────
// ALERTS GENERATOR
// ──────────────────────────────────────────────

/**
 * Generate actionable alerts from variance data
 *
 * @param {Object} varianceResult - From calculateVariance()
 * @param {Object} barVariance - From variancePerBar()
 * @returns {Array} Sorted alerts with severity and actionable messages
 */
function generateAlerts(varianceResult, barVariance) {
  const alerts = [];

  // Item-level alerts
  for (const alert of varianceResult.alerts) {
    alerts.push({
      type: 'ITEM_LOSS',
      severity: alert.severity,
      message: alert.message,
      item_name: alert.item_name,
      variance_dollars: alert.variance_dollars,
      variance_shots: alert.variance_shots,
      timestamp: varianceResult.timestamp
    });
  }

  // Bar-level alerts
  for (const bar of Object.values(barVariance)) {
    if (bar.severity !== 'OK') {
      alerts.push({
        type: 'BAR_LOSS',
        severity: bar.severity,
        message: `${bar.barName}: $${Math.abs(bar.total_variance_dollars)} unexplained loss`,
        bar_name: bar.barName,
        bar_id: bar.barId,
        variance_dollars: bar.total_variance_dollars,
        items_affected: bar.items.length,
        timestamp: varianceResult.timestamp
      });
    }
  }

  // Total event alert
  if (varianceResult.totals.severity !== 'OK') {
    alerts.push({
      type: 'EVENT_LOSS',
      severity: varianceResult.totals.severity,
      message: `Total event loss: $${Math.abs(varianceResult.totals.total_variance_dollars)} across ${varianceResult.totals.items_flagged} items`,
      variance_dollars: varianceResult.totals.total_variance_dollars,
      items_flagged: varianceResult.totals.items_flagged,
      timestamp: varianceResult.timestamp
    });
  }

  // Sort: HIGH first, then by dollar amount
  const severityOrder = { HIGH: 0, MEDIUM: 1, LOW: 2 };
  alerts.sort((a, b) =>
    (severityOrder[a.severity] || 3) - (severityOrder[b.severity] || 3) ||
    Math.abs(b.variance_dollars) - Math.abs(a.variance_dollars)
  );

  return alerts;
}


// ──────────────────────────────────────────────
// HELPER: Density lookup
// ──────────────────────────────────────────────

function getDensity(category) {
  if (!category) return VARIANCE_CONFIG.DEFAULT_DENSITY;
  return VARIANCE_CONFIG.DENSITY[category.toLowerCase()] || VARIANCE_CONFIG.DEFAULT_DENSITY;
}


// ──────────────────────────────────────────────
// MAIN: Run Full Variance Analysis
// ──────────────────────────────────────────────

/**
 * Run the complete POS ↔ Inventory variance analysis
 *
 * @param {Object} params
 * @param {Array} params.posOrders - Raw Square orders
 * @param {Array} params.events - BARINV events for this night
 * @param {Array} params.items - BARINV items array
 * @param {Array} params.bars - BARINV bars array
 * @param {Object} params.itemMapping - POS product name → BARINV item ID map (optional)
 * @returns {Object} Complete variance report with items, bars, totals, and alerts
 */
function runVarianceAnalysis({ posOrders, events, items, bars, itemMapping = {} }) {
  // Step 1: Calculate expected usage from POS
  const expected = posToExpectedUsage(posOrders, items, itemMapping);

  // Step 2: Calculate actual dispatched
  const dispatched = dispatchToActualSent(
    events.filter(e => e.action === 'DELIVERED' || e.action === 'REQUEST'),
    items
  );

  // Step 3: Calculate returns (weigh-based)
  const returned = returnsToActualRemaining(
    events.filter(e => e.action === 'RETURNED'),
    items
  );

  // Step 3b: Calculate intentional giveaways (COMP/SHOT/PROMO) so they are
  // excluded from unexplained variance. Passes the full events array —
  // giveawaysToMl filters internally by action.
  const giveaways = giveawaysToMl(events, items);

  // Step 4: Calculate variance
  const variance = calculateVariance(expected, dispatched, returned, items, giveaways);

  // Step 5: Break down by bar
  const barVariance = variancePerBar(variance, bars);

  // Step 6: Generate alerts
  const alerts = generateAlerts(variance, barVariance);

  return {
    // Core results
    items: variance.items,
    bars: barVariance,
    totals: variance.totals,
    alerts,

    // Raw data for debugging
    _debug: {
      expected_items: Object.keys(expected).length,
      dispatched_items: Object.keys(dispatched).length,
      returned_items: Object.keys(returned).length,
      pos_orders_processed: posOrders.length,
      events_processed: events.length
    }
  };
}


// ──────────────────────────────────────────────
// TIME-BASED VARIANCE (rolling window)
// ──────────────────────────────────────────────

/**
 * Calculate variance for a specific time window
 * Useful for real-time monitoring: "last 30 min", "last 1 hour"
 *
 * @param {Object} params - Same as runVarianceAnalysis
 * @param {number} windowMinutes - Time window in minutes (e.g., 30, 60)
 * @returns {Object} Variance report for the time window only
 */
function runTimeWindowVariance({ posOrders, events, items, bars, itemMapping = {} }, windowMinutes) {
  const cutoff = new Date(Date.now() - windowMinutes * 60000).toISOString();

  // Filter to only recent data
  const recentOrders = posOrders.filter(o => o.created_at >= cutoff);
  const recentEvents = events.filter(e => e.created_at >= cutoff);

  const result = runVarianceAnalysis({
    posOrders: recentOrders,
    events: recentEvents,
    items, bars, itemMapping
  });

  result.time_window = {
    minutes: windowMinutes,
    from: cutoff,
    to: new Date().toISOString(),
    orders_in_window: recentOrders.length,
    events_in_window: recentEvents.length
  };

  return result;
}


// ──────────────────────────────────────────────
// PERCENTAGE-BASED THRESHOLDS
// ──────────────────────────────────────────────

/**
 * Apply percentage-based thresholds instead of fixed dollar amounts
 * More useful for venues with different price points
 *
 * @param {Object} varianceResult - From calculateVariance()
 * @param {number} lowPct - Low threshold percentage (default 10%)
 * @param {number} medPct - Medium threshold percentage (default 20%)
 * @param {number} highPct - High threshold percentage (default 35%)
 * @returns {Object} Updated variance with percentage-based severity
 */
function applyPercentageThresholds(varianceResult, lowPct = 10, medPct = 20, highPct = 35) {
  const updated = JSON.parse(JSON.stringify(varianceResult)); // deep clone
  updated.alerts = [];

  for (const [id, item] of Object.entries(updated.items)) {
    const pct = Math.abs(item.variance_pct);

    if (item.ml_expected === 0 && item.ml_actual > 0) {
      // Missing bottle (no POS sales) — always HIGH
      item.severity = 'HIGH';
    } else if (pct > highPct) {
      item.severity = 'HIGH';
    } else if (pct > medPct) {
      item.severity = 'MEDIUM';
    } else if (pct > lowPct) {
      item.severity = 'LOW';
    } else {
      item.severity = 'OK';
    }

    if (item.severity !== 'OK') {
      updated.alerts.push({
        itemId: id,
        item_name: item.name,
        severity: item.severity,
        variance_pct: item.variance_pct,
        variance_dollars: item.variance_revenue,
        variance_shots: item.variance_shots,
        message: `${item.name}: ${Math.abs(item.variance_pct)}% variance ($${Math.abs(item.variance_revenue)})`
      });
    }
  }

  // Recalculate totals
  updated.totals.items_flagged = updated.alerts.length;
  const totalPct = updated.totals.total_expected_ml > 0
    ? Math.abs(updated.totals.total_variance_ml / updated.totals.total_expected_ml * 100)
    : 0;
  if (totalPct > highPct) updated.totals.severity = 'HIGH';
  else if (totalPct > medPct) updated.totals.severity = 'MEDIUM';
  else if (totalPct > lowPct) updated.totals.severity = 'LOW';
  else updated.totals.severity = 'OK';

  updated.alerts.sort((a, b) => {
    const so = { HIGH: 0, MEDIUM: 1, LOW: 2 };
    return (so[a.severity] || 3) - (so[b.severity] || 3) || Math.abs(b.variance_dollars) - Math.abs(a.variance_dollars);
  });

  return updated;
}


// ──────────────────────────────────────────────
// EXPORT (for use in index.html or Node.js)
// ──────────────────────────────────────────────

if (typeof window !== 'undefined') {
  // Browser — attach to window
  window.VarianceEngine = {
    run: runVarianceAnalysis,
    runTimeWindow: runTimeWindowVariance,
    applyPercentageThresholds,
    posToExpectedUsage,
    dispatchToActualSent,
    returnsToActualRemaining,
    giveawaysToMl,
    giveawayMl,
    classifyAlcohol,
    calculateVariance,
    variancePerBar,
    generateAlerts,
    CONFIG: VARIANCE_CONFIG
  };
}

if (typeof module !== 'undefined' && module.exports) {
  // Node.js — export for testing
  module.exports = {
    run: runVarianceAnalysis,
    runTimeWindow: runTimeWindowVariance,
    applyPercentageThresholds,
    posToExpectedUsage,
    dispatchToActualSent,
    returnsToActualRemaining,
    giveawaysToMl,
    giveawayMl,
    classifyAlcohol,
    calculateVariance,
    variancePerBar,
    generateAlerts,
    CONFIG: VARIANCE_CONFIG
  };
}
