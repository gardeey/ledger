import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/theme.dart';

class SankeyNode {
  SankeyNode(this.id, this.label, this.kind);
  final String id, label, kind;
  int col = 0;
  double value = 0, y = 0, h = 0, inOff = 0, outOff = 0;
  Color color = Colors.grey;
}

class SankeyLink {
  SankeyLink(this.s, this.t, this.value);
  final SankeyNode s, t;
  final double value;
  double sy = 0, ty = 0, h = 0;
}

class SankeyLayout {
  SankeyLayout(List<dynamic> rawNodes, List<dynamic> rawLinks) {
    for (final n in rawNodes) {
      nodes.add(SankeyNode(n['id'], n['label'], n['kind']));
    }
    final byId = {for (final n in nodes) n.id: n};
    for (final l in rawLinks) {
      final s = byId[l['source']], t = byId[l['target']];
      if (s != null && t != null) links.add(SankeyLink(s, t, (l['value'] as num).toDouble()));
    }
    // Column = longest path from a source (graph is a DAG).
    for (var i = 0; i < nodes.length; i++) {
      for (final l in links) {
        if (l.t.col <= l.s.col) l.t.col = l.s.col + 1;
      }
    }
    for (final n in nodes) {
      final i = links.where((l) => l.t == n).fold(0.0, (a, l) => a + l.value);
      final o = links.where((l) => l.s == n).fold(0.0, (a, l) => a + l.value);
      n.value = i > o ? i : o;
    }
    // Colour: each expense group gets a palette colour; its categories inherit it.
    var pi = 0;
    final groupColor = <String, Color>{};
    for (final n in nodes) {
      if (n.kind == 'group') groupColor[n.id.substring(2)] = kPalette[pi++ % kPalette.length];
    }
    for (final n in nodes) {
      switch (n.kind) {
        case 'income' || 'total': n.color = kGain;
        case 'savings': n.color = const Color(0xFF2EC4B6);
        case 'invest': n.color = const Color(0xFF7C5CFF);
        case 'deficit': n.color = kLoss;
        case 'group': n.color = groupColor[n.id.substring(2)]!;
        case 'category':
          final g = n.id.substring(2).split(':').first;
          n.color = (groupColor[g] ?? Colors.grey).withValues(alpha: 0.75);
      }
    }
  }

  final nodes = <SankeyNode>[];
  final links = <SankeyLink>[];
  int get columns => nodes.isEmpty ? 0 : nodes.map((n) => n.col).reduce((a, b) => a > b ? a : b) + 1;

  static const nodeW = 10.0;
  static const gap = 8.0;

  void layout(Size size, double labelPad) {
    final cols = columns;
    final byCol = List.generate(cols, (c) => nodes.where((n) => n.col == c).toList());
    // Uniform scale so the tallest column fills the height.
    var scale = double.infinity;
    for (final c in byCol) {
      if (c.isEmpty) continue;
      final sum = c.fold(0.0, (a, n) => a + n.value);
      final s = (size.height - gap * (c.length - 1)) / sum;
      if (s < scale) scale = s;
    }
    for (final c in byCol) {
      // Order by value so big flows sit on top; keep stable for readability.
      c.sort((a, b) => b.value.compareTo(a.value));
      final total = c.fold(0.0, (a, n) => a + n.value * scale) + gap * (c.length - 1);
      var y = (size.height - total) / 2;
      for (final n in c) {
        n.h = (n.value * scale).clamp(2.0, double.infinity);
        n.y = y;
        y += n.h + gap;
        n.inOff = 0;
        n.outOff = 0;
      }
    }
    final sortedByTarget = [...links]..sort((a, b) => a.t.y.compareTo(b.t.y));
    for (final l in sortedByTarget) {
      final h = l.value * scale;
      l.sy = l.s.y + l.s.outOff;
      l.s.outOff += h;
    }
    final sortedBySource = [...links]..sort((a, b) => a.s.y.compareTo(b.s.y));
    for (final l in sortedBySource) {
      final h = l.value * scale;
      l.ty = l.t.y + l.t.inOff;
      l.t.inOff += h;
      l.h = h;
    }
  }
}

class SankeyChart extends StatefulWidget {
  const SankeyChart({super.key, required this.nodes, required this.links, this.onNodeTap});
  final List<dynamic> nodes, links;
  final void Function(SankeyNode node, double total)? onNodeTap;

  @override
  State<SankeyChart> createState() => _SankeyChartState();
}

class _SankeyChartState extends State<SankeyChart> {
  SankeyNode? _active;

  @override
  Widget build(BuildContext context) {
    final lay = SankeyLayout(widget.nodes, widget.links);
    final incomeTotal = lay.nodes.where((n) => n.kind == 'total').fold(0.0, (a, n) => a + n.value);
    return LayoutBuilder(builder: (context, c) {
      final cols = lay.columns;
      final compact = c.maxWidth < 560;
      // Leaf labels are drawn to the right of the last column.
      final labelPad = compact ? 96.0 : 150.0;
      final h = (lay.nodes.length * 26.0).clamp(240.0, 460.0);
      final size = Size(c.maxWidth - labelPad, h);
      lay.layout(size, labelPad);
      final painter = _SankeyPainter(lay, size, cols, _active, Theme.of(context));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final hit = painter.hit(d.localPosition);
          setState(() => _active = hit == _active ? null : hit);
          if (hit != null) widget.onNodeTap?.call(hit, incomeTotal);
        },
        child: CustomPaint(size: Size(c.maxWidth, h), painter: painter),
      );
    });
  }
}

class _SankeyPainter extends CustomPainter {
  _SankeyPainter(this.lay, this.area, this.cols, this.active, this.theme);
  final SankeyLayout lay;
  final Size area;
  final int cols;
  final SankeyNode? active;
  final ThemeData theme;

  double colX(int c) => cols <= 1 ? 0 : c * (area.width - SankeyLayout.nodeW) / (cols - 1);

  SankeyNode? hit(Offset p) {
    for (final n in lay.nodes) {
      final r = Rect.fromLTWH(colX(n.col) - 6, n.y, SankeyLayout.nodeW + 12, n.h);
      if (r.contains(p)) return n;
    }
    return null;
  }

  bool _related(SankeyLink l) => active == null || l.s == active || l.t == active;

  @override
  void paint(Canvas canvas, Size size) {
    for (final l in lay.links) {
      final x0 = colX(l.s.col) + SankeyLayout.nodeW, x1 = colX(l.t.col);
      final mid = (x0 + x1) / 2;
      final h = l.h;
      final path = Path()
        ..moveTo(x0, l.sy)
        ..cubicTo(mid, l.sy, mid, l.ty, x1, l.ty)
        ..lineTo(x1, l.ty + h)
        ..cubicTo(mid, l.ty + h, mid, l.sy + h, x0, l.sy + h)
        ..close();
      // Ribbon takes the colour of the *destination* so each spend area reads as one hue.
      final base = l.t.kind == 'total' ? l.s.color : l.t.color;
      final a = _related(l) ? 0.38 : 0.08;
      canvas.drawPath(path, Paint()..color = base.withValues(alpha: a));
    }
    final text = theme.colorScheme.onSurface;
    for (final n in lay.nodes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(colX(n.col), n.y, SankeyLayout.nodeW, n.h), const Radius.circular(3)),
        Paint()..color = n.color,
      );
      final isLast = n.col == cols - 1 || lay.links.every((l) => l.s != n);
      final left = n.col == 0 && cols > 1 && n.kind == 'income';
      final tp = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: n.label, style: TextStyle(fontSize: 11.5, color: text, fontWeight: FontWeight.w600)),
          TextSpan(text: '  ${moneyCompact(n.value)}', style: TextStyle(fontSize: 11, color: text.withValues(alpha: .6))),
        ]),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: isLast ? size.width - area.width + SankeyLayout.nodeW - 6 : 130);
      if (isLast) {
        tp.paint(canvas, Offset(colX(n.col) + SankeyLayout.nodeW + 6, n.y + n.h / 2 - tp.height / 2));
      } else if (left) {
        tp.paint(canvas, Offset(colX(n.col) + SankeyLayout.nodeW + 4, n.y - tp.height - 2));
      } else if (n.h > 14) {
        // Middle-column labels sit just above the node to avoid ribbons.
        tp.paint(canvas, Offset(colX(n.col) + SankeyLayout.nodeW + 4, n.y - tp.height + 2));
      }
    }
  }

  @override
  bool shouldRepaint(_SankeyPainter old) => old.active != active || old.lay != lay || old.theme != theme;
}
