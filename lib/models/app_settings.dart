enum ScrollMode {
  /// 自动滚动（按行或匀速）
  auto,

  /// ASR 语音跟随
  asr,
}

/// 自动滚动的运动方式，与语音跟随独立保存。
enum AutoScrollMode { line, continuous }

enum AppBrightnessMode { system, light, dark }

/// 提词器应用设置
///
/// 管理所有用户可配置的提词器参数。
class AppSettings {
  static const defaultAsrModelId = 'zipformer2-ced';
  static const defaultAsrModelName = '中文语音模型（内置）';
  static const defaultCurrentCharColor = 0xFFFFD54F;
  static const defaultReadCharColor = 0xFF999999;
  static const minCurrentCharScale = 1.0;
  static const maxCurrentCharScale = 1.15;
  static const defaultCurrentCharScale = 1.10;
  static const defaultAnnotationColor = 0xFF8FA9B8;
  static const defaultAnnotationFontSize = 0.0;
  static const minAnnotationFontSize = 8.0;
  static const maxAnnotationFontSize = 36.0;

  static const annotationAppearanceKeys = <String>{
    'annotationFontFamily',
    'annotationFontSize',
    'annotationColor',
  };

  /// 只属于应用全局设置，不允许稿件覆盖或写入稿件快照。
  static const readingEmphasisKeys = <String>{
    'readingEmphasisEnabled',
    'currentCharColor',
    'readCharColor',
    'currentCharScale',
  };

  /// 字体大小（像素）
  final double fontSize;

  /// 行高倍数
  final double lineHeight;

  /// 滚动模式
  final ScrollMode scrollMode;

  /// 自动模式下的每分钟字数 (WPM)
  final int wpm;

  /// 自动模式默认按行跟随，可切换为像素匀速滚动。
  final AutoScrollMode autoScrollMode;

  /// 匀速滚动的逻辑像素/秒，支持负数和小数。
  final double pixelsPerSecond;

  /// 只有自动模式选择匀速时才隐藏阅读区域和当前字标记。
  bool get isContinuousScroll =>
      scrollMode == ScrollMode.auto &&
      autoScrollMode == AutoScrollMode.continuous;

  /// 当前自动模式对应的带符号速度。
  double get autoSpeed => isContinuousScroll ? pixelsPerSecond : wpm.toDouble();

  /// 是否启用镜像翻转（用于提词器分光镜）
  final bool mirrorMode;

  /// Paint-only coaching notes; saved per manuscript and synced with the session.
  final bool showAnnotations;

  /// 空字符串跟随正文；批注字体不改变正文排版。
  final String annotationFontFamily;

  /// 首选逻辑像素字号。0 保留原来的自动字号，空间不足时由渲染器收敛。
  final double annotationFontSize;

  /// 备注文字、字词框和引线共用的不透明颜色。
  final int annotationColor;

  /// 远程接收端的全屏启动偏好；本地提词始终以普通窗口进入。
  final bool fullScreenMode;

  /// 全屏时是否自动隐藏界面元素
  final bool autoHideUI;

  /// 全屏模式下自动隐藏的延迟秒数
  final int autoHideDelaySeconds;

  /// ASR 引擎类型标识
  final String asrModelId;

  /// 选中模型名称
  final String asrModelName;

  /// 主题色（金色）
  final int uiPrimaryColor;

  /// 提词器背景色
  final int teleprompterBgColor;

  /// 水平边距百分比（0~40，对应原文 paddingX）
  final double paddingX;

  /// 阅读线位置偏移比例（0.0~1.0，默认 0.5 = 居中）
  final double readingLineOffset;

  /// 是否加粗当前字
  final bool highlightCurrentChar;

  /// 整段变色与当前字放大的总开关；已读段标记由 grayReadChars 控制。
  final bool readingEmphasisEnabled;
  final int currentCharColor;
  final int readCharColor;
  final double currentCharScale;

  /// 正文字体默认加粗
  final bool defaultBold;

  /// 进度条提示字号占正文比例（默认 0.6 = 60%）
  final double progressInfoSizeRatio;

  /// ASR 模型下载镜像 URL（为空则用原始地址）
  final String asrMirrorUrl;

  /// Sherpa-Onnx worker thread count. Zero selects a device-based default.
  final int asrNumThreads;

  final double asrRule1MinTrailingSilence;
  final double asrRule2MinTrailingSilence;
  final double asrRule3MinUtteranceLength;

  final bool asrUseSystemProxy;

  /// Empty means the operating-system default input device.
  final String asrInputDeviceId;
  final String asrInputDeviceName;

  /// 应用 UI 字体（空字符串使用系统默认）
  final String appFontFamily;

  /// 提词器正文字体（空字符串使用系统默认）
  final String teleprompterFontFamily;

  /// 是否使用已读段落颜色
  final bool grayReadChars;

  /// 字体颜色（0 表示自动根据背景色选择黑白）
  final int textColor;

  /// 字间距（像素）
  final double letterSpacing;

  /// 当前字加下划线
  final bool underlineCurrentChar;

  /// 阅读区域框边框粗细（像素）
  final double readingAreaBorderWidth;

  /// 进度条显示 - 已用时间
  final bool progressShowTime;

  /// 进度条显示 - 进度百分比
  final bool progressShowPercentage;

  /// 进度条显示 - 滚动速度（自动模式）
  final bool progressShowSpeed;

  /// 进度条显示 - 当前时间
  final bool progressShowCurrentTime;

  /// 应用亮暗模式（不影响提词器播放页）
  final AppBrightnessMode appBrightnessMode;

  /// 启动时直接进入临时稿件编辑器。
  final bool quickModeEnabled;

  /// 快速模式是否自动保存稿件。
  final bool quickModeAutoSave;

  /// 快速模式自动保存目录，空字符串表示根目录。
  final String quickModeFolderId;

  const AppSettings({
    this.quickModeEnabled = false,
    this.quickModeAutoSave = false,
    this.quickModeFolderId = '',
    this.fontSize = 64,
    this.lineHeight = 1.5,
    this.scrollMode = ScrollMode.auto,
    this.wpm = 150,
    this.autoScrollMode = AutoScrollMode.line,
    this.pixelsPerSecond = 20,
    this.mirrorMode = false,
    this.showAnnotations = true,
    this.annotationFontFamily = '',
    this.annotationFontSize = defaultAnnotationFontSize,
    this.annotationColor = defaultAnnotationColor,
    this.fullScreenMode = false,
    this.autoHideUI = true,
    this.autoHideDelaySeconds = 3,
    this.asrModelId = defaultAsrModelId,
    this.asrModelName = defaultAsrModelName,
    this.uiPrimaryColor = 0xFFDB9D16,
    this.teleprompterBgColor = 0xFF000000,
    this.paddingX = 5.0,
    this.readingLineOffset = 0.5,
    this.highlightCurrentChar = false,
    this.readingEmphasisEnabled = true,
    this.currentCharColor = defaultCurrentCharColor,
    this.readCharColor = defaultReadCharColor,
    this.currentCharScale = defaultCurrentCharScale,
    this.defaultBold = true,
    this.progressInfoSizeRatio = 0.6,
    this.asrMirrorUrl = '',
    this.asrNumThreads = 0,
    this.asrRule1MinTrailingSilence = 2.4,
    this.asrRule2MinTrailingSilence = 1.2,
    this.asrRule3MinUtteranceLength = 20.0,
    this.asrUseSystemProxy = true,
    this.asrInputDeviceId = '',
    this.asrInputDeviceName = '',
    this.appFontFamily = 'Noto Sans SC',
    this.teleprompterFontFamily = 'Noto Sans SC',
    this.grayReadChars = true,
    this.textColor = 0,
    this.letterSpacing = 0.0,
    this.underlineCurrentChar = false,
    this.readingAreaBorderWidth = 3.0,
    this.progressShowTime = true,
    this.progressShowPercentage = true,
    this.progressShowSpeed = true,
    this.progressShowCurrentTime = true,
    this.appBrightnessMode = AppBrightnessMode.dark,
  });

  /// 从 JSON 反序列化
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final storedModelId = (json['asrModelId'] as String?)?.trim() ?? '';
    final modelId = storedModelId.isEmpty ? defaultAsrModelId : storedModelId;
    final storedModelName = (json['asrModelName'] as String?)?.trim() ?? '';
    final modelName =
        storedModelId.isEmpty ||
            (modelId == defaultAsrModelId && storedModelName.isEmpty)
        ? defaultAsrModelName
        : storedModelName;
    return AppSettings(
      quickModeEnabled: json['quickModeEnabled'] as bool? ?? false,
      quickModeAutoSave: json['quickModeAutoSave'] as bool? ?? false,
      quickModeFolderId: json['quickModeFolderId'] as String? ?? '',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 64,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.5,
      scrollMode: ScrollMode.values.firstWhere(
        (e) => e.name == json['scrollMode'],
        orElse: () => ScrollMode.auto,
      ),
      wpm: (json['wpm'] as num?)?.toInt() ?? 150,
      autoScrollMode: AutoScrollMode.values.firstWhere(
        (e) => e.name == json['autoScrollMode'],
        orElse: () => AutoScrollMode.line,
      ),
      pixelsPerSecond: (json['pixelsPerSecond'] as num?)?.toDouble() ?? 20,
      mirrorMode: json['mirrorMode'] as bool? ?? false,
      showAnnotations: json['showAnnotations'] is bool
          ? json['showAnnotations'] as bool
          : true,
      annotationFontFamily: normalizeAnnotationFontFamily(
        json['annotationFontFamily'],
      ),
      annotationFontSize: normalizeAnnotationFontSize(
        json['annotationFontSize'],
      ),
      annotationColor: normalizeAnnotationColor(json['annotationColor']),
      fullScreenMode: json['fullScreenMode'] as bool? ?? false,
      autoHideUI: json['autoHideUI'] as bool? ?? true,
      autoHideDelaySeconds: json['autoHideDelaySeconds'] as int? ?? 3,
      asrModelId: modelId,
      asrModelName: modelName,
      uiPrimaryColor: json['uiPrimaryColor'] as int? ?? 0xFFDB9D16,
      teleprompterBgColor: json['teleprompterBgColor'] as int? ?? 0xFF000000,
      paddingX: (json['paddingX'] as num?)?.toDouble() ?? 5.0,
      readingLineOffset: (json['readingLineOffset'] as num?)?.toDouble() ?? 0.5,
      highlightCurrentChar: json['highlightCurrentChar'] as bool? ?? false,
      readingEmphasisEnabled: json['readingEmphasisEnabled'] is bool
          ? json['readingEmphasisEnabled'] as bool
          : true,
      currentCharColor: _storedColor(
        json['currentCharColor'],
        defaultCurrentCharColor,
      ),
      readCharColor: _storedColor(json['readCharColor'], defaultReadCharColor),
      currentCharScale: _storedScale(json['currentCharScale']),
      defaultBold: json['defaultBold'] as bool? ?? true,
      progressInfoSizeRatio:
          (json['progressInfoSizeRatio'] as num?)?.toDouble() ?? 0.6,
      asrMirrorUrl: json['asrMirrorUrl'] as String? ?? '',
      asrNumThreads: (json['asrNumThreads'] as num?)?.toInt() ?? 0,
      asrRule1MinTrailingSilence:
          (json['asrRule1MinTrailingSilence'] as num?)?.toDouble() ?? 2.4,
      asrRule2MinTrailingSilence:
          (json['asrRule2MinTrailingSilence'] as num?)?.toDouble() ?? 1.2,
      asrRule3MinUtteranceLength:
          (json['asrRule3MinUtteranceLength'] as num?)?.toDouble() ?? 20.0,
      asrUseSystemProxy: json['asrUseSystemProxy'] as bool? ?? true,
      asrInputDeviceId: json['asrInputDeviceId'] as String? ?? '',
      asrInputDeviceName: json['asrInputDeviceName'] as String? ?? '',
      appFontFamily: json['appFontFamily'] as String? ?? 'Noto Sans SC',
      teleprompterFontFamily:
          json['teleprompterFontFamily'] as String? ?? 'Noto Sans SC',
      grayReadChars: json['grayReadChars'] as bool? ?? true,
      textColor: json['textColor'] as int? ?? 0,
      letterSpacing: (json['letterSpacing'] as num?)?.toDouble() ?? 0.0,
      underlineCurrentChar: json['underlineCurrentChar'] as bool? ?? false,
      readingAreaBorderWidth:
          (json['readingAreaBorderWidth'] as num?)?.toDouble() ?? 3.0,
      progressShowTime: json['progressShowTime'] as bool? ?? true,
      progressShowPercentage: json['progressShowPercentage'] as bool? ?? true,
      progressShowSpeed: json['progressShowSpeed'] as bool? ?? true,
      progressShowCurrentTime: json['progressShowCurrentTime'] as bool? ?? true,
      appBrightnessMode: AppBrightnessMode.values.firstWhere(
        (e) => e.name == json['appBrightnessMode'],
        orElse: () => AppBrightnessMode.dark,
      ),
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() {
    return {
      'quickModeEnabled': quickModeEnabled,
      'quickModeAutoSave': quickModeAutoSave,
      'quickModeFolderId': quickModeFolderId,
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'scrollMode': scrollMode.name,
      'wpm': wpm,
      'autoScrollMode': autoScrollMode.name,
      'pixelsPerSecond': pixelsPerSecond,
      'mirrorMode': mirrorMode,
      'showAnnotations': showAnnotations,
      ...toAnnotationAppearanceMap(),
      'fullScreenMode': fullScreenMode,
      'autoHideUI': autoHideUI,
      'autoHideDelaySeconds': autoHideDelaySeconds,
      'asrModelId': asrModelId,
      'asrModelName': asrModelName,
      'uiPrimaryColor': uiPrimaryColor,
      'teleprompterBgColor': teleprompterBgColor,
      'paddingX': paddingX,
      'readingLineOffset': readingLineOffset,
      'highlightCurrentChar': highlightCurrentChar,
      ...toReadingEmphasisMap(),
      'defaultBold': defaultBold,
      'progressInfoSizeRatio': progressInfoSizeRatio,
      'asrMirrorUrl': asrMirrorUrl,
      'asrNumThreads': asrNumThreads,
      'asrRule1MinTrailingSilence': asrRule1MinTrailingSilence,
      'asrRule2MinTrailingSilence': asrRule2MinTrailingSilence,
      'asrRule3MinUtteranceLength': asrRule3MinUtteranceLength,
      'asrUseSystemProxy': asrUseSystemProxy,
      'asrInputDeviceId': asrInputDeviceId,
      'asrInputDeviceName': asrInputDeviceName,
      'appFontFamily': appFontFamily,
      'teleprompterFontFamily': teleprompterFontFamily,
      'grayReadChars': grayReadChars,
      'textColor': textColor,
      'letterSpacing': letterSpacing,
      'underlineCurrentChar': underlineCurrentChar,
      'readingAreaBorderWidth': readingAreaBorderWidth,
      'progressShowTime': progressShowTime,
      'progressShowPercentage': progressShowPercentage,
      'progressShowSpeed': progressShowSpeed,
      'progressShowCurrentTime': progressShowCurrentTime,
      'appBrightnessMode': appBrightnessMode.name,
    };
  }

  /// 创建副本并修改部分字段
  AppSettings copyWith({
    bool? quickModeEnabled,
    bool? quickModeAutoSave,
    String? quickModeFolderId,
    double? fontSize,
    double? lineHeight,
    ScrollMode? scrollMode,
    int? wpm,
    AutoScrollMode? autoScrollMode,
    double? pixelsPerSecond,
    bool? mirrorMode,
    bool? showAnnotations,
    String? annotationFontFamily,
    double? annotationFontSize,
    int? annotationColor,
    bool? fullScreenMode,
    bool? autoHideUI,
    int? autoHideDelaySeconds,
    String? asrModelId,
    String? asrModelName,
    int? uiPrimaryColor,
    int? teleprompterBgColor,
    double? paddingX,
    double? readingLineOffset,
    double? progressInfoSizeRatio,
    String? asrMirrorUrl,
    int? asrNumThreads,
    double? asrRule1MinTrailingSilence,
    double? asrRule2MinTrailingSilence,
    double? asrRule3MinUtteranceLength,
    bool? asrUseSystemProxy,
    String? asrInputDeviceId,
    String? asrInputDeviceName,
    String? appFontFamily,
    String? teleprompterFontFamily,
    bool? grayReadChars,
    int? textColor,
    double? letterSpacing,
    bool? highlightCurrentChar,
    bool? readingEmphasisEnabled,
    int? currentCharColor,
    int? readCharColor,
    double? currentCharScale,
    bool? defaultBold,
    bool? underlineCurrentChar,
    double? readingAreaBorderWidth,
    bool? progressShowTime,
    bool? progressShowPercentage,
    bool? progressShowSpeed,
    bool? progressShowCurrentTime,
    AppBrightnessMode? appBrightnessMode,
  }) {
    return AppSettings(
      quickModeEnabled: quickModeEnabled ?? this.quickModeEnabled,
      quickModeAutoSave: quickModeAutoSave ?? this.quickModeAutoSave,
      quickModeFolderId: quickModeFolderId ?? this.quickModeFolderId,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      scrollMode: scrollMode ?? this.scrollMode,
      wpm: wpm ?? this.wpm,
      autoScrollMode: autoScrollMode ?? this.autoScrollMode,
      pixelsPerSecond: pixelsPerSecond ?? this.pixelsPerSecond,
      mirrorMode: mirrorMode ?? this.mirrorMode,
      showAnnotations: showAnnotations ?? this.showAnnotations,
      annotationFontFamily: normalizeAnnotationFontFamily(
        annotationFontFamily ?? this.annotationFontFamily,
      ),
      annotationFontSize: normalizeAnnotationFontSize(
        annotationFontSize ?? this.annotationFontSize,
      ),
      annotationColor: normalizeAnnotationColor(
        annotationColor ?? this.annotationColor,
      ),
      fullScreenMode: fullScreenMode ?? this.fullScreenMode,
      autoHideUI: autoHideUI ?? this.autoHideUI,
      autoHideDelaySeconds: autoHideDelaySeconds ?? this.autoHideDelaySeconds,
      asrModelId: asrModelId ?? this.asrModelId,
      asrModelName: asrModelName ?? this.asrModelName,
      uiPrimaryColor: uiPrimaryColor ?? this.uiPrimaryColor,
      teleprompterBgColor: teleprompterBgColor ?? this.teleprompterBgColor,
      paddingX: paddingX ?? this.paddingX,
      readingLineOffset: readingLineOffset ?? this.readingLineOffset,
      progressInfoSizeRatio:
          progressInfoSizeRatio ?? this.progressInfoSizeRatio,
      asrMirrorUrl: asrMirrorUrl ?? this.asrMirrorUrl,
      asrNumThreads: asrNumThreads ?? this.asrNumThreads,
      asrRule1MinTrailingSilence:
          asrRule1MinTrailingSilence ?? this.asrRule1MinTrailingSilence,
      asrRule2MinTrailingSilence:
          asrRule2MinTrailingSilence ?? this.asrRule2MinTrailingSilence,
      asrRule3MinUtteranceLength:
          asrRule3MinUtteranceLength ?? this.asrRule3MinUtteranceLength,
      asrUseSystemProxy: asrUseSystemProxy ?? this.asrUseSystemProxy,
      asrInputDeviceId: asrInputDeviceId ?? this.asrInputDeviceId,
      asrInputDeviceName: asrInputDeviceName ?? this.asrInputDeviceName,
      appFontFamily: appFontFamily ?? this.appFontFamily,
      teleprompterFontFamily:
          teleprompterFontFamily ?? this.teleprompterFontFamily,
      grayReadChars: grayReadChars ?? this.grayReadChars,
      textColor: textColor ?? this.textColor,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      highlightCurrentChar: highlightCurrentChar ?? this.highlightCurrentChar,
      readingEmphasisEnabled:
          readingEmphasisEnabled ?? this.readingEmphasisEnabled,
      currentCharColor: _storedColor(
        currentCharColor ?? this.currentCharColor,
        defaultCurrentCharColor,
      ),
      readCharColor: _storedColor(
        readCharColor ?? this.readCharColor,
        defaultReadCharColor,
      ),
      currentCharScale: _storedScale(currentCharScale ?? this.currentCharScale),
      defaultBold: defaultBold ?? this.defaultBold,
      underlineCurrentChar: underlineCurrentChar ?? this.underlineCurrentChar,
      readingAreaBorderWidth:
          readingAreaBorderWidth ?? this.readingAreaBorderWidth,
      progressShowTime: progressShowTime ?? this.progressShowTime,
      progressShowPercentage:
          progressShowPercentage ?? this.progressShowPercentage,
      progressShowSpeed: progressShowSpeed ?? this.progressShowSpeed,
      progressShowCurrentTime:
          progressShowCurrentTime ?? this.progressShowCurrentTime,
      appBrightnessMode: appBrightnessMode ?? this.appBrightnessMode,
    );
  }

  /// 用稿件覆盖设置合并生成新的 AppSettings
  /// 仅覆盖提词器相关字段，全局设置（ASR、主题色等）保持当前值
  AppSettings mergeOverrides(Map<String, dynamic> overrides) {
    if (overrides.isEmpty) return this;
    return AppSettings(
      quickModeEnabled: quickModeEnabled,
      quickModeAutoSave: quickModeAutoSave,
      quickModeFolderId: quickModeFolderId,
      fontSize: (overrides['fontSize'] as num?)?.toDouble() ?? fontSize,
      lineHeight: (overrides['lineHeight'] as num?)?.toDouble() ?? lineHeight,
      scrollMode: overrides.containsKey('scrollMode')
          ? ScrollMode.values.firstWhere(
              (e) => e.name == overrides['scrollMode'],
              orElse: () => scrollMode,
            )
          : scrollMode,
      wpm: (overrides['wpm'] as num?)?.toInt() ?? wpm,
      autoScrollMode: AutoScrollMode.values.firstWhere(
        (e) => e.name == overrides['autoScrollMode'],
        orElse: () => autoScrollMode,
      ),
      pixelsPerSecond:
          (overrides['pixelsPerSecond'] as num?)?.toDouble() ?? pixelsPerSecond,
      mirrorMode: overrides['mirrorMode'] as bool? ?? mirrorMode,
      showAnnotations: overrides['showAnnotations'] is bool
          ? overrides['showAnnotations'] as bool
          : showAnnotations,
      annotationFontFamily: normalizeAnnotationFontFamily(
        overrides['annotationFontFamily'],
        fallback: annotationFontFamily,
      ),
      annotationFontSize: normalizeAnnotationFontSize(
        overrides['annotationFontSize'],
        fallback: annotationFontSize,
      ),
      annotationColor: normalizeAnnotationColor(
        overrides['annotationColor'],
        fallback: annotationColor,
      ),
      fullScreenMode: overrides['fullScreenMode'] as bool? ?? fullScreenMode,
      autoHideUI: overrides['autoHideUI'] as bool? ?? autoHideUI,
      autoHideDelaySeconds:
          overrides['autoHideDelaySeconds'] as int? ?? autoHideDelaySeconds,
      paddingX: (overrides['paddingX'] as num?)?.toDouble() ?? paddingX,
      readingLineOffset:
          (overrides['readingLineOffset'] as num?)?.toDouble() ??
          readingLineOffset,
      highlightCurrentChar:
          overrides['highlightCurrentChar'] as bool? ?? highlightCurrentChar,
      defaultBold: overrides['defaultBold'] as bool? ?? defaultBold,
      progressInfoSizeRatio:
          (overrides['progressInfoSizeRatio'] as num?)?.toDouble() ??
          progressInfoSizeRatio,
      teleprompterFontFamily:
          overrides['teleprompterFontFamily'] as String? ??
          teleprompterFontFamily,
      grayReadChars: overrides['grayReadChars'] as bool? ?? grayReadChars,
      textColor: overrides['textColor'] as int? ?? textColor,
      letterSpacing:
          (overrides['letterSpacing'] as num?)?.toDouble() ?? letterSpacing,
      underlineCurrentChar:
          overrides['underlineCurrentChar'] as bool? ?? underlineCurrentChar,
      readingAreaBorderWidth:
          (overrides['readingAreaBorderWidth'] as num?)?.toDouble() ??
          readingAreaBorderWidth,
      teleprompterBgColor:
          overrides['teleprompterBgColor'] as int? ?? teleprompterBgColor,
      // 以下全局设置始终使用当前值，不被稿件覆盖
      readingEmphasisEnabled: readingEmphasisEnabled,
      currentCharColor: currentCharColor,
      readCharColor: readCharColor,
      currentCharScale: currentCharScale,
      asrModelId: asrModelId,
      asrModelName: asrModelName,
      uiPrimaryColor: uiPrimaryColor,
      appFontFamily: appFontFamily,
      asrMirrorUrl: asrMirrorUrl,
      asrNumThreads: asrNumThreads,
      asrRule1MinTrailingSilence: asrRule1MinTrailingSilence,
      asrRule2MinTrailingSilence: asrRule2MinTrailingSilence,
      asrRule3MinUtteranceLength: asrRule3MinUtteranceLength,
      asrUseSystemProxy: asrUseSystemProxy,
      asrInputDeviceId: asrInputDeviceId,
      asrInputDeviceName: asrInputDeviceName,
      progressShowTime:
          overrides['progressShowTime'] as bool? ?? progressShowTime,
      progressShowPercentage:
          overrides['progressShowPercentage'] as bool? ??
          progressShowPercentage,
      progressShowSpeed:
          overrides['progressShowSpeed'] as bool? ?? progressShowSpeed,
      progressShowCurrentTime:
          overrides['progressShowCurrentTime'] as bool? ??
          progressShowCurrentTime,
      appBrightnessMode: appBrightnessMode,
    );
  }

  /// 导出提词器相关设置为 Map（用于保存到稿件）
  Map<String, dynamic> toTeleprompterMap() {
    return {
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'scrollMode': scrollMode.name,
      'wpm': wpm,
      'autoScrollMode': autoScrollMode.name,
      'pixelsPerSecond': pixelsPerSecond,
      'mirrorMode': mirrorMode,
      'showAnnotations': showAnnotations,
      ...toAnnotationAppearanceMap(),
      'paddingX': paddingX,
      'readingLineOffset': readingLineOffset,
      'highlightCurrentChar': highlightCurrentChar,
      'defaultBold': defaultBold,
      'progressInfoSizeRatio': progressInfoSizeRatio,
      'teleprompterFontFamily': teleprompterFontFamily,
      'grayReadChars': grayReadChars,
      'textColor': textColor,
      'letterSpacing': letterSpacing,
      'teleprompterBgColor': teleprompterBgColor,
      'underlineCurrentChar': underlineCurrentChar,
      'readingAreaBorderWidth': readingAreaBorderWidth,
      'progressShowTime': progressShowTime,
      'progressShowPercentage': progressShowPercentage,
      'progressShowSpeed': progressShowSpeed,
      'progressShowCurrentTime': progressShowCurrentTime,
    };
  }

  /// 会话可携带全局显示状态，但稿件持久化必须继续用 toTeleprompterMap。
  Map<String, dynamic> toSessionMap() => {
    ...toTeleprompterMap(),
    ...toReadingEmphasisMap(),
  };

  Map<String, dynamic> toAnnotationAppearanceMap() => {
    'annotationFontFamily': annotationFontFamily,
    'annotationFontSize': annotationFontSize,
    'annotationColor': annotationColor,
  };

  /// 字体来源于本机列表或稿件备份；损坏的单项不能使整份设置加载失败。
  static String normalizeAnnotationFontFamily(
    Object? value, {
    String fallback = '',
  }) {
    if (value is! String) return fallback;
    final family = value.trim();
    if (family.length > 200 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(family)) {
      return fallback;
    }
    return family;
  }

  static double normalizeAnnotationFontSize(
    Object? value, {
    double fallback = defaultAnnotationFontSize,
  }) {
    if (value is! num || !value.isFinite || value < 0) return fallback;
    if (value == 0) return defaultAnnotationFontSize;
    return value.clamp(minAnnotationFontSize, maxAnnotationFontSize).toDouble();
  }

  static int normalizeAnnotationColor(
    Object? value, {
    int fallback = defaultAnnotationColor,
  }) {
    if (value is! int || value < 0 || value > 0xFFFFFFFF) return fallback;
    // 不允许意外的透明通道把备注、字词框和引线一并隐藏。
    return value | 0xFF000000;
  }

  Map<String, dynamic> toReadingEmphasisMap() => {
    'readingEmphasisEnabled': readingEmphasisEnabled,
    'currentCharColor': currentCharColor,
    'readCharColor': readCharColor,
    'currentCharScale': currentCharScale,
  };

  /// 交互和协议输入采用严格校验，防止错误值被当作已成功保存。
  static Map<String, dynamic> validateReadingEmphasisPatch(
    Map<String, dynamic> patch,
  ) {
    if (patch.isEmpty) throw const FormatException('缺少当前字突出设置');
    final validated = <String, dynamic>{};
    for (final entry in patch.entries) {
      if (!readingEmphasisKeys.contains(entry.key)) {
        throw const FormatException('包含不支持的当前字突出设置');
      }
      final value = entry.value;
      switch (entry.key) {
        case 'readingEmphasisEnabled':
          if (value is! bool) {
            throw const FormatException('当前字突出开关必须是布尔值');
          }
          validated[entry.key] = value;
        case 'currentCharColor':
        case 'readCharColor':
          if (value is! int || value < 0 || value > 0xFFFFFFFF) {
            throw const FormatException('文字颜色必须是有效的32位颜色值');
          }
          validated[entry.key] = value;
        case 'currentCharScale':
          if (value is! num ||
              !value.isFinite ||
              value < minCurrentCharScale ||
              value > maxCurrentCharScale) {
            throw const FormatException('当前字放大倍数必须在1.00至1.15之间');
          }
          validated[entry.key] = value.toDouble();
      }
    }
    return validated;
  }

  AppSettings withReadingEmphasisPatch(Map<String, dynamic> patch) {
    final values = validateReadingEmphasisPatch(patch);
    return copyWith(
      readingEmphasisEnabled: values['readingEmphasisEnabled'] as bool?,
      currentCharColor: values['currentCharColor'] as int?,
      readCharColor: values['readCharColor'] as int?,
      currentCharScale: values['currentCharScale'] as double?,
    );
  }

  // 老版本没有这些字段；损坏的单项只回退自身，不能丢掉模型等其他设置。
  static int _storedColor(Object? value, int fallback) =>
      value is int && value >= 0 && value <= 0xFFFFFFFF ? value : fallback;

  static double _storedScale(Object? value) => value is num && value.isFinite
      ? value.clamp(minCurrentCharScale, maxCurrentCharScale).toDouble()
      : defaultCurrentCharScale;
}
