// LAN Messenger 架构风险报告 — 图表初始化
(function () {
  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var sevHigh = style.getPropertyValue('--sev-high').trim() || '#DC2626';
  var sevMid = style.getPropertyValue('--sev-mid').trim() || '#D97706';
  var sevLow = style.getPropertyValue('--sev-low').trim() || '#64748B';

  var el = document.getElementById('chart-risk-dist');
  if (!el || typeof echarts === 'undefined') {
    if (el) { el.innerHTML = '<p style="color:' + muted + ';padding:24px;font-size:14px;">图表库加载失败，数据见表 1.1 风险矩阵。</p>'; }
    return;
  }

  var chart = echarts.init(el, null, { renderer: 'svg' });
  chart.setOption({
    animation: false,
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      appendToBody: true,
      formatter: function (params) {
        var total = 0;
        var lines = [params[0].name];
        params.forEach(function (p) {
          total += p.value;
          lines.push(p.marker + ' ' + p.seriesName + '：' + p.value + ' 项');
        });
        lines.push('合计：' + total + ' 项');
        return lines.join('<br/>');
      }
    },
    legend: {
      data: ['高风险', '中风险', '低风险'],
      top: 0,
      textStyle: { color: muted, fontSize: 12 }
    },
    grid: { left: 130, right: 40, top: 36, bottom: 24 },
    xAxis: {
      type: 'value',
      minInterval: 1,
      axisLabel: { color: muted, fontSize: 12 },
      splitLine: { lineStyle: { color: rule } }
    },
    yAxis: {
      type: 'category',
      data: ['传输与接入', '凭据与存储', '可用性与部署', '数据一致性', '性能', '访问控制与工程'],
      axisLabel: { color: ink, fontSize: 13 },
      axisLine: { lineStyle: { color: rule } },
      axisTick: { show: false }
    },
    series: [
      {
        name: '高风险',
        type: 'bar',
        stack: 'total',
        barMaxWidth: 22,
        itemStyle: { color: sevHigh, borderRadius: [3, 0, 0, 3] },
        data: [1, 1, 1, 0, 1, 0]
      },
      {
        name: '中风险',
        type: 'bar',
        stack: 'total',
        barMaxWidth: 22,
        itemStyle: { color: sevMid },
        data: [0, 2, 2, 1, 0, 1]
      },
      {
        name: '低风险',
        type: 'bar',
        stack: 'total',
        barMaxWidth: 22,
        itemStyle: { color: sevLow, borderRadius: [0, 3, 3, 0] },
        data: [2, 0, 0, 2, 2, 2]
      }
    ]
  });

  window.addEventListener('resize', function () { chart.resize(); });
})();
