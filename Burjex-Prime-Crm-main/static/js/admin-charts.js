/**
 * Shared Chart.js defaults and helpers for admin dashboards.
 * Load after Chart.js (UMD).
 */
(function () {
  "use strict";
  if (typeof Chart === "undefined") {
    return;
  }

  var eliteHybrid =
    typeof document !== "undefined" &&
    document.body &&
    document.body.classList &&
    document.body.classList.contains("admin-elite-hybrid");

  var fontStack = "'Segoe UI', system-ui, -apple-system, BlinkMacSystemFont, Roboto, sans-serif";

  Chart.defaults.font.family = fontStack;
  Chart.defaults.font.size = 12;
  Chart.defaults.color = "#64748b";
  Chart.defaults.borderColor = eliteHybrid ? "rgba(226, 232, 240, 0.95)" : "rgba(148, 163, 184, 0.35)";
  Chart.defaults.backgroundColor = eliteHybrid ? "rgba(108, 93, 211, 0.1)" : "rgba(148, 163, 184, 0.12)";
  Chart.defaults.plugins.legend.position = "bottom";
  Chart.defaults.plugins.legend.align = "start";
  Chart.defaults.plugins.legend.labels.boxWidth = 10;
  Chart.defaults.plugins.legend.labels.boxHeight = 10;
  Chart.defaults.plugins.legend.labels.padding = 14;
  Chart.defaults.plugins.legend.labels.usePointStyle = true;
  if (eliteHybrid) {
    Chart.defaults.plugins.legend.labels.color = "#475569";
  }
  Chart.defaults.plugins.tooltip.padding = 10;
  Chart.defaults.plugins.tooltip.cornerRadius = 8;
  Chart.defaults.plugins.tooltip.backgroundColor = eliteVip ? "rgba(17, 24, 39, 0.96)" : "rgba(15, 23, 42, 0.92)";
  Chart.defaults.plugins.tooltip.titleFont = { size: 12, weight: "600" };
  Chart.defaults.plugins.tooltip.bodyFont = { size: 12 };
  Chart.defaults.plugins.tooltip.displayColors = true;
  Chart.defaults.animation.duration = 550;
  Chart.defaults.animation.easing = "easeOutQuart";
  Chart.defaults.elements.line.borderWidth = 2;
  Chart.defaults.elements.point.radius = 3;
  Chart.defaults.elements.point.hoverRadius = 5;
  Chart.defaults.scale.grid.color = eliteHybrid ? "rgba(148, 163, 184, 0.35)" : "rgba(148, 163, 184, 0.2)";
  Chart.defaults.scale.ticks.maxTicksLimit = 10;

  function fmtMoney(v) {
    var n = Number(v);
    if (Number.isNaN(n)) {
      return "—";
    }
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: "USD",
      minimumFractionDigits: 0,
      maximumFractionDigits: 2,
    }).format(n);
  }

  function fmtCompactMoney(v) {
    var n = Number(v);
    if (Number.isNaN(n)) {
      return "—";
    }
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: "USD",
      notation: "compact",
      maximumFractionDigits: 1,
    }).format(n);
  }

  function fmtInt(v) {
    var n = Number(v);
    if (Number.isNaN(n)) {
      return "—";
    }
    return new Intl.NumberFormat().format(Math.round(n));
  }

  window.AdminCharts = {
    fmtMoney: fmtMoney,
    fmtInt: fmtInt,
    fmtCompactMoney: fmtCompactMoney,

    cartesianScalesMoney: function (yExtra) {
      var y = Object.assign(
        {
          beginAtZero: true,
          border: { display: false },
          ticks: {
            callback: function (value) {
              return fmtCompactMoney(value);
            },
          },
        },
        yExtra || {}
      );
      return {
        x: {
          grid: { display: false },
          border: { display: false },
          ticks: { maxRotation: 45, minRotation: 0, autoSkip: true },
        },
        y: y,
      };
    },

    cartesianScalesInt: function (yExtra) {
      var y = Object.assign(
        {
          beginAtZero: true,
          border: { display: false },
          ticks: {
            precision: 0,
            callback: function (value) {
              return fmtInt(value);
            },
          },
        },
        yExtra || {}
      );
      return {
        x: {
          grid: { display: false },
          border: { display: false },
          ticks: { maxRotation: 45, minRotation: 0, autoSkip: true },
        },
        y: y,
      };
    },

    tooltipMoneyIndex: function () {
      return {
        mode: "index",
        intersect: false,
        callbacks: {
          label: function (ctx) {
            var label = ctx.dataset.label ? ctx.dataset.label + ": " : "";
            var raw = ctx.parsed.y !== undefined ? ctx.parsed.y : ctx.parsed;
            return label + fmtMoney(raw);
          },
        },
      };
    },

    tooltipIntIndex: function () {
      return {
        mode: "index",
        intersect: false,
        callbacks: {
          label: function (ctx) {
            var label = ctx.dataset.label ? ctx.dataset.label + ": " : "";
            var raw = ctx.parsed.y !== undefined ? ctx.parsed.y : ctx.parsed;
            return label + fmtInt(raw);
          },
        },
      };
    },

    tooltipMixedDualAxis: function () {
      return {
        mode: "index",
        intersect: false,
        callbacks: {
          label: function (ctx) {
            var label = ctx.dataset.label ? ctx.dataset.label + ": " : "";
            var raw = ctx.parsed.y !== undefined ? ctx.parsed.y : ctx.parsed;
            if (ctx.dataset.yAxisID === "y1") {
              return label + fmtInt(raw);
            }
            return label + fmtMoney(raw);
          },
        },
      };
    },

    doughnutColors: function (n) {
      var base = [
        "#0B3C5D",
        "#10B981",
        "#2563EB",
        "#7C3AED",
        "#F59E0B",
        "#EF4444",
        "#06B6D4",
        "#EC4899",
        "#84CC16",
        "#6366F1",
      ];
      var out = [];
      for (var i = 0; i < n; i++) {
        out.push(base[i % base.length]);
      }
      return out;
    },
  };
})();
