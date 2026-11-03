import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'experimental_tap_gateway.dart';

/// Apple Music 风格 CD 封面组件（响应式 vh 单位）
///
/// 视觉层次（从外到内）：
/// 1. 白色圆角卡片容器（Jewel Case 外壳，尺寸 = 48vh，max 380px）
/// 2. 透明塑料盒内壳（半透明白色 + 边缘高光模拟厚度）
/// 3. CD 光盘（彩虹 SweepGradient + 深色数据环 + 同心圆纹理 + 光泽旋转）
/// 4. 银色金属 hub（RadialGradient + 放射状纹理 + 中心孔）
/// 5. 红色方形标签（#FF0000，绝对定位于光盘右上方）
///
/// 所有尺寸基于屏幕高度 (vh) 计算，适配不同分辨率。
/// 交互：五连击 CD 卡片区域触发 [onExitTrigger] 回调退出页面
class MusicCdCover extends StatefulWidget {
  final String? coverImagePath;
  final String title;
  final String artist;
  final String album;
  final VoidCallback? onExitTrigger;

  /// CD 卡片尺寸（可选）。若不传则基于屏幕高度自动计算。
  /// 由父组件传入可确保在横屏小屏上不超出可用空间。
  final double? cdSize;

  const MusicCdCover({
    super.key,
    this.coverImagePath,
    required this.title,
    this.artist = '',
    this.album = '',
    this.onExitTrigger,
    this.cdSize,
  });

  @override
  State<MusicCdCover> createState() => _MusicCdCoverState();
}

class _MusicCdCoverState extends State<MusicCdCover>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;
  late Animation<double> _rotationAnimation;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 25),
    )..repeat();
    _rotationAnimation = Tween<double>(
      begin: 0.0,
      end: 2 * math.pi,
    ).animate(_rotationController);
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeOutBack,
    );
    _scaleController.forward();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    // CD 卡片尺寸：优先使用父组件传入的值，否则基于 48vh 自动计算
    // clamp 下限降到 120 以适配横屏手机（高360dp 时 48vh=172）
    final cdSize = widget.cdSize ?? (screenHeight * 0.48).clamp(120.0, 380.0);
    // CD 光盘直径 = 卡片尺寸的 88%
    final discSize = cdSize * 0.88;
    // 封面到歌曲信息间距：5vh，clamp 12~48（小屏降低下限）
    final infoGap = (screenHeight * 0.05).clamp(12.0, 48.0);
    // 歌曲名字号：基于 CD 尺寸比例计算，而非固定 vh
    // 原 340px 对应 15px，即 cdSize * 0.044
    final titleSize = (cdSize * 0.044).clamp(11.0, 22.0);
    // 艺术家字号：cdSize * 0.038
    final artistSize = (cdSize * 0.038).clamp(9.0, 16.0);

    return ScaleTransition(
      scale: _scaleAnimation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildJewelCase(cdSize, discSize),
          SizedBox(height: infoGap),
          _buildSongInfo(cdSize, titleSize, artistSize, screenHeight),
        ],
      ),
    );
  }

  /// 构建 Jewel Case 透明塑料盒 + CD 光盘 + 红色标签
  Widget _buildJewelCase(double cdSize, double discSize) {
    final borderRadius = cdSize * 0.035; // ~12px/340
    return ExperimentalTapGateway(
      onTrigger: () => widget.onExitTrigger?.call(),
      child: Container(
        width: cdSize,
        height: cdSize,
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F5),
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: cdSize * 0.15,
              offset: Offset(0, cdSize * 0.035),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Stack(
            alignment: Alignment.center,
            children: [
              _buildPlasticCaseInner(borderRadius),
              _buildCdDisc(discSize),
              _buildRedLabel(cdSize),
            ],
          ),
        ),
      ),
    );
  }

  /// 透明塑料盒内壳：模拟 Jewel Case 塑料厚度与反光
  Widget _buildPlasticCaseInner(double borderRadius) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.4),
            width: 1.5,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.25),
              Colors.white.withValues(alpha: 0.05),
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: 0.08),
            ],
            stops: const [0.0, 0.3, 0.6, 1.0],
          ),
        ),
      ),
    );
  }

  /// CD 光盘：CustomPainter 绘制彩虹反射 + 银色 hub + 光泽动画
  Widget _buildCdDisc(double discSize) {
    return SizedBox(
      width: discSize,
      height: discSize,
      child: AnimatedBuilder(
        animation: _rotationAnimation,
        builder: (context, _) {
          return CustomPaint(
            size: Size(discSize, discSize),
            painter: _CdDiscPainter(rotationAngle: _rotationAnimation.value),
          );
        },
      ),
    );
  }

  /// 红色方形标签（#FF0000，位于光盘右上方偏移）
  Widget _buildRedLabel(double cdSize) {
    final labelW = cdSize * 0.176; // ~60/340
    final labelH = cdSize * 0.206; // ~70/340
    final offset = cdSize * 0.082; // ~28/340
    return Positioned(
      top: offset,
      right: offset,
      child: Transform.rotate(
        angle: -0.08,
        child: Container(
          width: labelW,
          height: labelH,
          decoration: BoxDecoration(
            color: const Color(0xFFFF0000),
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: cdSize * 0.024,
                offset: Offset(cdSize * 0.006, cdSize * 0.009),
              ),
            ],
          ),
          child: Center(
            child: Text(
              '♪',
              style: TextStyle(
                color: Colors.white,
                fontSize: cdSize * 0.082,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 2 行歌曲信息（Apple Music 风格）
  /// 第1行：歌曲名 — 白色, ~2.5vh, w600
  /// 第2行：艺术家 — 专辑名 — 白色70%透明, ~2vh, w400
  Widget _buildSongInfo(
    double cdSize,
    double titleSize,
    double artistSize,
    double screenHeight,
  ) {
    // 歌曲名到艺术家间距：1vh
    final lineGap = (screenHeight * 0.01).clamp(6.0, 12.0);
    return SizedBox(
      width: cdSize,
      child: Column(
        children: [
          Text(
            widget.title.isNotEmpty ? widget.title : '未知曲目',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: titleSize,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: 0.1,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (widget.artist.isNotEmpty || widget.album.isNotEmpty) ...[
            SizedBox(height: lineGap),
            Text(
              [
                widget.artist,
                widget.album,
              ].where((s) => s.isNotEmpty).join(' \u2014 '),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: artistSize,
                fontWeight: FontWeight.w400,
                color: Colors.white.withValues(alpha: 0.7),
                letterSpacing: 0.1,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// CD 光盘绘制器（全比例缩放，基于 size 自适应）
class _CdDiscPainter extends CustomPainter {
  final double rotationAngle;

  _CdDiscPainter({required this.rotationAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final discRadius = size.width / 2 - 2;
    // 缩放因子：基于原始 300px 设计稿
    final s = size.width / 300.0;

    // === 1. 彩虹光谱反射底层 ===
    final rainbowPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          const Color(0xFFFF6B6B),
          const Color(0xFFFFA94C),
          const Color(0xFFFFD43B),
          const Color(0xFF69DB7C),
          const Color(0xFF4DABF7),
          const Color(0xFF748FFC),
          const Color(0xFFDA77F2),
          const Color(0xFFFF6B6B),
        ],
        startAngle: rotationAngle,
        endAngle: rotationAngle + 2 * math.pi,
        transform: GradientRotation(rotationAngle),
      ).createShader(Rect.fromCircle(center: center, radius: discRadius));
    canvas.drawCircle(center, discRadius, rainbowPaint);

    // === 2. 数据区深色外环 ===
    final dataRingPaint = Paint()
      ..color = const Color(0xFF1A1A1A).withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8 * s;
    canvas.drawCircle(center, discRadius - 4 * s, dataRingPaint);

    // === 3. 同心圆表面纹理线 ===
    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    for (double r = 38 * s; r < discRadius - 8 * s; r += 5 * s) {
      canvas.drawCircle(center, r, ringPaint);
    }

    // === 4. 光泽反射层（旋转的线性渐变）===
    final glossPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.12),
          Colors.transparent,
          Colors.transparent,
          Colors.white.withValues(alpha: 0.06),
        ],
        stops: const [0.0, 0.35, 0.65, 1.0],
        transform: GradientRotation(rotationAngle * 1.5),
      ).createShader(Rect.fromCircle(center: center, radius: discRadius));
    canvas.drawCircle(center, discRadius - 4 * s, glossPaint);

    // === 5. 银色金属 hub ===
    final hubRadius = 26.0 * s;
    final hubPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white,
          const Color(0xFFE0E0E6),
          const Color(0xFF9A9AA2),
          const Color(0xFFB8B8C0),
          const Color(0xFF7A7A82),
        ],
        stops: const [0.0, 0.35, 0.55, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: hubRadius));
    canvas.drawCircle(center, hubRadius, hubPaint);

    // === 5b. 放射状纹理短线段 ===
    final spokePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..strokeWidth = 0.6;
    for (int i = 0; i < 32; i++) {
      final angle = (i / 32) * 2 * math.pi;
      final start = Offset(
        center.dx + 9 * s * math.cos(angle),
        center.dy + 9 * s * math.sin(angle),
      );
      final end = Offset(
        center.dx + (hubRadius - 2 * s) * math.cos(angle),
        center.dy + (hubRadius - 2 * s) * math.sin(angle),
      );
      canvas.drawLine(start, end, spokePaint);
    }

    // === 5c. hub 外圈金属环 ===
    final hubRingPaint = Paint()
      ..color = const Color(0xFF6A6A72)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, hubRadius, hubRingPaint);

    // === 6. 中心小孔 ===
    final holeRadius = 6.0 * s;
    final holePaint = Paint()..color = const Color(0xFF1C1C1E);
    canvas.drawCircle(center, holeRadius, holePaint);

    // 中心孔边缘高光
    final holeRingPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawCircle(center, holeRadius * 1.08, holeRingPaint);
  }

  @override
  bool shouldRepaint(covariant _CdDiscPainter oldDelegate) {
    return oldDelegate.rotationAngle != rotationAngle;
  }
}
