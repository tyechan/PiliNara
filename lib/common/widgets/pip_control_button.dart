import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

/// 小窗控制按钮:固定触控目标 + hover 高亮。
///
/// 参照安卓系统 PiP 的按键触控设计:
/// - 主操作(底部播放/暂停/±10秒)用 [targetSize] 默认 48dp 的触控目标,
///   图标居中四周留白——与 AOSP `pip_action_size=48dp` 一致,便于手指盲操;
/// - 次要操作(关闭/还原)传小 [targetSize],仅比图标大一圈,降低误触。
///
/// 触控目标由外层布局约束自适应:小窗较窄(竖屏视频/最小缩放)时会被
/// 约束收缩,不会溢出。桌面鼠标 hover 时显示白色半透明圆角底,与系统
/// PiP 的 hover 反馈一致,同时直观展示触控范围。
///
/// 注意:GestureDetector 默认 deferToChild 下,Padding 空白区不参与命中,
/// 因此必须 [HitTestBehavior.opaque] 让整个盒子可点——否则触控目标会
/// 缩回图标本身大小。
class PipControlButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final double targetSize;

  const PipControlButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.targetSize = 48,
  });

  @override
  State<PipControlButton> createState() => _PipControlButtonState();
}

class _PipControlButtonState extends State<PipControlButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox.square(
          dimension: widget.targetSize,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: _hovering
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(child: widget.icon),
          ),
        ),
      ),
    );
  }
}

/// Play/pause for the in-app mini window.
///
/// [PlPlayerController.playerStatus] is a plain enum after upstream
/// `e4185e5b1` (not an Rx). Wrapping `playerStatus == playing` in Obx
/// throws GetX "improper use of Obx" and becomes a grey ErrorWidget that
/// fills the unconstrained mini-window Row. Listen to media_kit instead,
/// same as [PlayOrPauseButton].
class PipPlayPauseButton extends StatelessWidget {
  const PipPlayPauseButton({
    super.key,
    required this.targetSize,
    required this.onToggle,
    this.player,
    this.isPlaying = false,
  });

  final double targetSize;
  final VoidCallback onToggle;
  final Player? player;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final player = this.player;
    if (player == null) {
      return _icon(isPlaying);
    }
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snapshot) => _icon(snapshot.data ?? false),
    );
  }

  Widget _icon(bool playing) {
    return PipControlButton(
      targetSize: targetSize,
      onTap: onToggle,
      icon: Icon(
        playing ? Icons.pause : Icons.play_arrow,
        color: Colors.white,
        size: 30,
      ),
    );
  }
}
