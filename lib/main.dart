import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(TimesheetApp(prefs: prefs));
}

// ============================================================================
// DATA MODELS & BUSINESS LOGIC
// ============================================================================

enum DayStatus { empty, incomplete, complete }

class DayEntry {
  final int dayNumber;
  String? checkIn; // Format: "HH:mm"
  String? checkOut; // Format: "HH:mm"
  int breakMinutes;
  String note;

  DayEntry({
    required this.dayNumber,
    this.checkIn,
    this.checkOut,
    this.breakMinutes = 0,
    this.note = '',
  });

  DayStatus get status {
    if ((checkIn == null || checkIn!.isEmpty) &&
        (checkOut == null || checkOut!.isEmpty)) {
      return DayStatus.empty;
    }
    if (checkIn != null &&
        checkIn!.isNotEmpty &&
        checkOut != null &&
        checkOut!.isNotEmpty) {
      return DayStatus.complete;
    }
    return DayStatus.incomplete;
  }

  /// Calculates net worked minutes for the day, handling overnight shifts
  /// (e.g., 22:00 to 02:00 = 240 minutes) and deducting break time.
  int get netMinutesWorked {
    if (status != DayStatus.complete) return 0;

    final inParts = checkIn!.split(':');
    final outParts = checkOut!.split(':');
    if (inParts.length != 2 || outParts.length != 2) return 0;

    final inTotalMinutes =
        int.parse(inParts[0]) * 60 + int.parse(inParts[1]);
    int outTotalMinutes =
        int.parse(outParts[0]) * 60 + int.parse(outParts[1]);

    // Overnight shift detection: if check-out is smaller than check-in, add 24 hours
    if (outTotalMinutes < inTotalMinutes) {
      outTotalMinutes += 24 * 60;
    }

    final rawDuration = outTotalMinutes - inTotalMinutes;
    final netDuration = rawDuration - breakMinutes;

    return netDuration > 0 ? netDuration : 0;
  }

  bool get isOvernightShift {
    if (status != DayStatus.complete) return false;
    final inParts = checkIn!.split(':');
    final outParts = checkOut!.split(':');
    final inMins = int.parse(inParts[0]) * 60 + int.parse(inParts[1]);
    final outMins = int.parse(outParts[0]) * 60 + int.parse(outParts[1]);
    return outMins < inMins;
  }

  String get formattedNetDuration => TimeFormatter.formatMinutes(netMinutesWorked);

  Map<String, dynamic> toJson() => {
        'dayNumber': dayNumber,
        'checkIn': checkIn,
        'checkOut': checkOut,
        'breakMinutes': breakMinutes,
        'note': note,
      };

  factory DayEntry.fromJson(Map<String, dynamic> json) => DayEntry(
        dayNumber: json['dayNumber'] as int,
        checkIn: json['checkIn'] as String?,
        checkOut: json['checkOut'] as String?,
        breakMinutes: (json['breakMinutes'] as int?) ?? 0,
        note: (json['note'] as String?) ?? '',
      );
}

class MonthSheet {
  String id;
  String title;
  int totalDaysInMonth; // 29, 30, or 31
  int targetHours; // e.g., 192
  DateTime createdAt;
  List<DayEntry> days;

  MonthSheet({
    required this.id,
    required this.title,
    required this.totalDaysInMonth,
    required this.targetHours,
    required this.createdAt,
    required this.days,
  });

  factory MonthSheet.createNew({
    String title = 'ماه جاری',
    int totalDays = 30,
    int targetHours = 192,
  }) {
    return MonthSheet(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      totalDaysInMonth: totalDays,
      targetHours: targetHours,
      createdAt: DateTime.now(),
      days: List.generate(31, (index) => DayEntry(dayNumber: index + 1)),
    );
  }

  List<DayEntry> get activeDays => days.take(totalDaysInMonth).toList();

  int get totalMinutesWorked =>
      activeDays.fold(0, (sum, day) => sum + day.netMinutesWorked);

  int get totalDaysWorked =>
      activeDays.where((d) => d.status == DayStatus.complete).length;

  int get incompleteDaysCount =>
      activeDays.where((d) => d.status == DayStatus.incomplete).length;

  int get targetMinutes => targetHours * 60;

  /// Positive = Overtime (اضافه‌کاری), Negative = Deficit (کسری کار)
  int get balanceMinutes => totalMinutesWorked - targetMinutes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'totalDaysInMonth': totalDaysInMonth,
        'targetHours': targetHours,
        'createdAt': createdAt.toIso8601String(),
        'days': days.map((d) => d.toJson()).toList(),
      };

  factory MonthSheet.fromJson(Map<String, dynamic> json) {
    final loadedDays = (json['days'] as List)
        .map((e) => DayEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    // Ensure we always have 31 slots in memory so toggling 29/30/31 never loses data
    while (loadedDays.length < 31) {
      loadedDays.add(DayEntry(dayNumber: loadedDays.length + 1));
    }
    return MonthSheet(
      id: json['id'] as String,
      title: json['title'] as String,
      totalDaysInMonth: (json['totalDaysInMonth'] as int?) ?? 30,
      targetHours: (json['targetHours'] as int?) ?? 192,
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      days: loadedDays,
    );
  }
}

class TimeFormatter {
  /// Converts total minutes into standard HH:MM with base-60 rollover
  static String formatMinutes(int totalMinutes, {bool showSign = false}) {
    final isNegative = totalMinutes < 0;
    final absMinutes = totalMinutes.abs();
    final hours = absMinutes ~/ 60;
    final minutes = absMinutes % 60;

    final hStr = hours.toString().padLeft(2, '0');
    final mStr = minutes.toString().padLeft(2, '0');

    if (showSign) {
      final sign = isNegative ? '-' : '+';
      return '$sign$hStr:$mStr';
    }
    return '$hStr:$mStr';
  }

  static String formatTimeOfDay(TimeOfDay time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static TimeOfDay? parseTimeOfDay(String? timeStr) {
    if (timeStr == null || !timeStr.contains(':')) return null;
    final parts = timeStr.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 8,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }
}

// ============================================================================
// MAIN APP WIDGET & THEME CONTROLLER
// ============================================================================

class TimesheetApp extends StatefulWidget {
  final SharedPreferences prefs;
  const TimesheetApp({super.key, required this.prefs});

  @override
  State<TimesheetApp> createState() => _TimesheetAppState();
}

class _TimesheetAppState extends State<TimesheetApp> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    final savedTheme = widget.prefs.getString('theme_mode') ?? 'system';
    _themeMode = savedTheme == 'dark'
        ? ThemeMode.dark
        : savedTheme == 'light'
            ? ThemeMode.light
            : ThemeMode.system;
  }

  void _toggleTheme() {
    setState(() {
      if (_themeMode == ThemeMode.dark) {
        _themeMode = ThemeMode.light;
        widget.prefs.setString('theme_mode', 'light');
      } else {
        _themeMode = ThemeMode.dark;
        widget.prefs.setString('theme_mode', 'dark');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'تایم‌شیت و ساعت کاری',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF006A6A),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4DB6AC),
        brightness: Brightness.dark,
      ),
      home: HomeScreen(
        prefs: widget.prefs,
        onToggleTheme: _toggleTheme,
        isDarkMode: _themeMode == ThemeMode.dark,
      ),
    );
  }
}

// ============================================================================
// HOME SCREEN
// ============================================================================

class HomeScreen extends StatefulWidget {
  final SharedPreferences prefs;
  final VoidCallback onToggleTheme;
  final bool isDarkMode;

  const HomeScreen({
    super.key,
    required this.prefs,
    required this.onToggleTheme,
    required this.isDarkMode,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _currentSheetKey = 'current_month_sheet_v1';
  static const String _archiveListKey = 'archived_month_sheets_v1';

  late MonthSheet _currentSheet;
  List<MonthSheet> _archives = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    final currentJson = widget.prefs.getString(_currentSheetKey);
    if (currentJson != null) {
      try {
        _currentSheet = MonthSheet.fromJson(jsonDecode(currentJson));
      } catch (_) {
        _currentSheet = MonthSheet.createNew();
      }
    } else {
      _currentSheet = MonthSheet.createNew();
    }

    final archivesJson = widget.prefs.getStringList(_archiveListKey) ?? [];
    _archives = archivesJson
        .map((str) {
          try {
            return MonthSheet.fromJson(jsonDecode(str));
          } catch (_) {
            return null;
          }
        })
        .whereType<MonthSheet>()
        .toList();
  }

  Future<void> _saveCurrentSheet() async {
    await widget.prefs.setString(
      _currentSheetKey,
      jsonEncode(_currentSheet.toJson()),
    );
    setState(() {});
  }

  Future<void> _saveArchives() async {
    final encodedList =
        _archives.map((sheet) => jsonEncode(sheet.toJson())).toList();
    await widget.prefs.setStringList(_archiveListKey, encodedList);
    setState(() {});
  }

  // --------------------------------------------------------------------------
  // QUICK PUNCH NOW ACTION
  // --------------------------------------------------------------------------

  void _handleQuickPunch() {
    final nowStr = TimeFormatter.formatTimeOfDay(TimeOfDay.now());

    // Find the first incomplete day, or first empty day, or default to Day 1
    DayEntry? targetDay = _currentSheet.activeDays.cast<DayEntry?>().firstWhere(
          (d) => d!.status == DayStatus.incomplete,
          orElse: () => null,
        );

    targetDay ??= _currentSheet.activeDays.cast<DayEntry?>().firstWhere(
          (d) => d!.status == DayStatus.empty,
          orElse: () => _currentSheet.activeDays.first,
        );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        int selectedDayNum = targetDay!.dayNumber;
        return StatefulBuilder(
          builder: (context, setModalState) {
            final currentDayObj = _currentSheet.days[selectedDayNum - 1];
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'ثبت سریع ساعت فعلی ($nowStr)',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Icon(Icons.bolt, color: Colors.amber, size: 28),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    value: selectedDayNum,
                    decoration: const InputDecoration(
                      labelText: 'انتخاب روز ماه',
                      border: OutlineInputBorder(),
                    ),
                    items: _currentSheet.activeDays.map((d) {
                      String statusLabel = '';
                      if (d.status == DayStatus.complete) {
                        statusLabel = ' (تکمیل: ${d.checkIn} تا ${d.checkOut})';
                      } else if (d.status == DayStatus.incomplete) {
                        statusLabel =
                            ' (ناقص - ورود: ${d.checkIn ?? "-"} / خروج: ${d.checkOut ?? "-"})';
                      } else {
                        statusLabel = ' (خالی)';
                      }
                      return DropdownMenuItem<int>(
                        value: d.dayNumber,
                        child: Text('روز ${d.dayNumber}$statusLabel'),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setModalState(() => selectedDayNum = val);
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            currentDayObj.checkIn = nowStr;
                            _saveCurrentSheet();
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'ساعت ورود روز $selectedDayNum روی $nowStr ثبت شد.'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.login),
                          label: const Text('ثبت به عنوان ورود'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            currentDayObj.checkOut = nowStr;
                            _saveCurrentSheet();
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'ساعت خروج روز $selectedDayNum روی $nowStr ثبت شد.'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.logout),
                          label: const Text('ثبت به عنوان خروج'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // SETTINGS & TARGET HOURS DIALOG
  // --------------------------------------------------------------------------

  void _showSettingsDialog() {
    final titleController = TextEditingController(text: _currentSheet.title);
    final targetController =
        TextEditingController(text: _currentSheet.targetHours.toString());
    int selectedDays = _currentSheet.totalDaysInMonth;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تنظیمات ماه جاری'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'نام یا عنوان ماه (مثال: فروردین ۱۴۰۵)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: targetController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'ساعت موظفی ماهانه (ساعت)',
                    helperText: 'مثال: ۱۹۲ یا ۱۷۶ ساعت در ماه',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'تعداد روزهای ماه:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 29, label: Text('۲۹ روز')),
                    ButtonSegment(value: 30, label: Text('۳۰ روز')),
                    ButtonSegment(value: 31, label: Text('۳۱ روز')),
                  ],
                  selected: {selectedDays},
                  onSelectionChanged: (newSelection) {
                    setDialogState(() {
                      selectedDays = newSelection.first;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () {
                _currentSheet.title = titleController.text.trim().isEmpty
                    ? 'ماه جاری'
                    : titleController.text.trim();
                _currentSheet.targetHours =
                    int.tryParse(targetController.text) ?? 192;
                _currentSheet.totalDaysInMonth = selectedDays;
                _saveCurrentSheet();
                Navigator.pop(ctx);
              },
              child: const Text('ذخیره تغییرات'),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // ARCHIVE & NEW MONTH MANAGEMENT
  // --------------------------------------------------------------------------

  void _showNewMonthOrArchiveDialog() {
    final newTitleController = TextEditingController(text: 'ماه جدید');
    bool archiveCurrent = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع ماه جدید / بایگانی'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'آیا می‌خواهید جدول ماه فعلی را ببندید و یک ماه جدید و خالی شروع کنید؟',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: archiveCurrent,
                onChanged: (val) =>
                    setDialogState(() => archiveCurrent = val ?? true),
                title: Text('ذخیره «${_currentSheet.title}» در بایگانی'),
                subtitle: const Text('امکان مشاهده و بارگذاری مجدد در آینده'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: newTitleController,
                decoration: const InputDecoration(
                  labelText: 'عنوان ماه جدید',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () async {
                if (archiveCurrent) {
                  _archives.removeWhere((a) => a.id == _currentSheet.id);
                  _archives.insert(0, _currentSheet);
                  await _saveArchives();
                }
                _currentSheet = MonthSheet.createNew(
                  title: newTitleController.text.trim().isEmpty
                      ? 'ماه جدید'
                      : newTitleController.text.trim(),
                  totalDays: _currentSheet.totalDaysInMonth,
                  targetHours: _currentSheet.targetHours,
                );
                await _saveCurrentSheet();
                if (context.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ماه جدید با موفقیت ایجاد شد.')),
                  );
                }
              },
              child: const Text('تایید و شروع ماه جدید'),
            ),
          ],
        ),
      ),
    );
  }

  void _showArchivesModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (_, scrollController) => Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'بایگانی ماه‌های گذشته (${_archives.length})',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showNewMonthOrArchiveDialog();
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('ماه جدید'),
                    ),
                  ],
                ),
                const Divider(height: 24),
                if (_archives.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Text('هنوز هیچ ماهی بایگانی نشده است.'),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _archives.length,
                      itemBuilder: (context, index) {
                        final item = _archives[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            title: Text(
                              item.title,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              'مجموع کارکرد: ${TimeFormatter.formatMinutes(item.totalMinutesWorked)} | روزهای کاری: ${item.totalDaysWorked} از ${item.totalDaysInMonth}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'بارگذاری این ماه',
                                  icon: const Icon(Icons.restore),
                                  onPressed: () async {
                                    // Save current before switching
                                    _archives.removeWhere(
                                        (a) => a.id == _currentSheet.id);
                                    _archives.insert(0, _currentSheet);
                                    _currentSheet = item;
                                    _archives
                                        .removeWhere((a) => a.id == item.id);
                                    await _saveArchives();
                                    await _saveCurrentSheet();
                                    if (context.mounted) Navigator.pop(ctx);
                                  },
                                ),
                                IconButton(
                                  tooltip: 'حذف از بایگانی',
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                  onPressed: () async {
                                    _archives.removeAt(index);
                                    await _saveArchives();
                                    setModalState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // EXPORT & SHARE (TEXT & CSV FOR EXCEL)
  // --------------------------------------------------------------------------

  String _generateTextReport() {
    final sb = StringBuffer();
    sb.writeln('📊 گزارش کارکرد ماهانه: ${_currentSheet.title}');
    sb.writeln('══════════════════════════');
    for (final d in _currentSheet.activeDays) {
      if (d.status == DayStatus.complete) {
        final breakInfo =
            d.breakMinutes > 0 ? ' (کسر استراحت: ${d.breakMinutes} دقیقه)' : '';
        final noteInfo = d.note.isNotEmpty ? ' | توضیح: ${d.note}' : '';
        sb.writeln(
          '• روز ${d.dayNumber}: ${d.checkIn} تا ${d.checkOut} ⬅ خالص: ${d.formattedNetDuration}$breakInfo$noteInfo',
        );
      } else if (d.status == DayStatus.incomplete) {
        sb.writeln(
          '• روز ${d.dayNumber}: ناقص (ورود: ${d.checkIn ?? "--:--"} | خروج: ${d.checkOut ?? "--:--"})',
        );
      }
    }
    sb.writeln('══════════════════════════');
    sb.writeln('📅 تعداد روزهای کاری: ${_currentSheet.totalDaysWorked} روز');
    sb.writeln(
      '⏱ مجموع کل ساعات کاری: ${TimeFormatter.formatMinutes(_currentSheet.totalMinutesWorked)}',
    );
    sb.writeln('🎯 ساعت موظفی ماه: ${_currentSheet.targetHours}:00');
    final bal = _currentSheet.balanceMinutes;
    final balTitle = bal >= 0 ? 'اضافه‌کاری' : 'کسری کار';
    sb.writeln(
      '⚖️ وضعیت ($balTitle): ${TimeFormatter.formatMinutes(bal, showSign: true)}',
    );
    return sb.toString();
  }

  String _generateCsvContent() {
    // Include UTF-8 BOM (\uFEFF) so Microsoft Excel opens Persian characters properly
    final sb = StringBuffer('\uFEFF');
    sb.writeln(
        'روز,ساعت ورود,ساعت خروج,کسر استراحت (دقیقه),کارکرد خالص (HH:MM),توضیحات / پروژه');
    for (final d in _currentSheet.activeDays) {
      final safeNote = d.note.replaceAll(',', ' - ').replaceAll('\n', ' ');
      sb.writeln(
        'روز ${d.dayNumber},${d.checkIn ?? ""},${d.checkOut ?? ""},${d.breakMinutes},${d.status == DayStatus.complete ? d.formattedNetDuration : "00:00"},$safeNote',
      );
    }
    sb.writeln('');
    sb.writeln(
        'جمع کل کارکرد,,,,${TimeFormatter.formatMinutes(_currentSheet.totalMinutesWorked)},');
    sb.writeln('روزهای کارکرد,,,,${_currentSheet.totalDaysWorked},');
    sb.writeln('ساعت موظفی,,,,${_currentSheet.targetHours}:00,');
    sb.writeln(
        'تراز (اضافه/کسری),,,,${TimeFormatter.formatMinutes(_currentSheet.balanceMinutes, showSign: true)},');
    return sb.toString();
  }

  void _showExportModal() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'خروجی گرفتن و اشتراک‌گذاری (${_currentSheet.title})',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.table_view)),
              title: const Text('خروجی فایل اکسل (CSV)'),
              subtitle: const Text(
                  'مناسب برای باز کردن در Excel، تلگرام، واتساپ یا ایمیل'),
              onTap: () async {
                Navigator.pop(ctx);
                final csvData = _generateCsvContent();
                final tempDir = await getTemporaryDirectory();
                final file = File(
                    '${tempDir.path}/timesheet_${_currentSheet.id}.csv');
                await file.writeAsString(csvData);
                await Share.shareXFiles(
                  [XFile(file.path, mimeType: 'text/csv')],
                  subject: 'گزارش تایم‌شیت ${_currentSheet.title}',
                );
              },
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.share)),
              title: const Text('ارسال خلاصه متنی (تلگرام / واتساپ)'),
              subtitle: const Text(
                  'ارسال گزارش مرتب متنی به پیام‌رسان‌ها و ایمیل'),
              onTap: () {
                Navigator.pop(ctx);
                Share.share(_generateTextReport());
              },
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.copy)),
              title: const Text('کپی گزارش در حافظه (Clipboard)'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: _generateTextReport()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('گزارش متنی در حافظه موقت کپی شد.')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // BUILD UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _showSettingsDialog,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _currentSheet.title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.edit_outlined, size: 18),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'خروجی و اشتراک‌گذاری',
            icon: const Icon(Icons.ios_share),
            onPressed: _showExportModal,
          ),
          IconButton(
            tooltip: 'بایگانی و ماه جدید',
            icon: const Icon(Icons.folder_copy_outlined),
            onPressed: _showArchivesModal,
          ),
          IconButton(
            tooltip: 'تنظیمات ماه (${_currentSheet.totalDaysInMonth} روزه)',
            icon: const Icon(Icons.tune),
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            tooltip: 'تغییر پوسته شب/روز',
            icon: Icon(
                widget.isDarkMode ? Icons.light_mode : Icons.dark_mode_outlined),
            onPressed: widget.onToggleTheme,
          ),
        ],
      ),
      body: Column(
        children: [
          // STICKY GRAND TOTAL DASHBOARD HEADER
          GrandTotalDashboard(
            sheet: _currentSheet,
            onTapTargetSettings: _showSettingsDialog,
          ),
          // SCROLLABLE 29/30/31 DAYS LIST
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 88),
              itemCount: _currentSheet.totalDaysInMonth,
              itemBuilder: (context, index) {
                final dayEntry = _currentSheet.days[index];
                return DayRowCard(
                  key: ValueKey('day_${_currentSheet.id}_${dayEntry.dayNumber}'),
                  entry: dayEntry,
                  onChanged: _saveCurrentSheet,
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _handleQuickPunch,
        icon: const Icon(Icons.access_time_filled),
        label: const Text('ثبت الان'),
      ),
    );
  }
}

// ============================================================================
// STICKY GRAND TOTAL DASHBOARD WIDGET
// ============================================================================

class GrandTotalDashboard extends StatelessWidget {
  final MonthSheet sheet;
  final VoidCallback onTapTargetSettings;

  const GrandTotalDashboard({
    super.key,
    required this.sheet,
    required this.onTapTargetSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balanceMins = sheet.balanceMinutes;
    final isAhead = balanceMins >= 0;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.65),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.25),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  label: 'مجموع ساعات کاری',
                  value: TimeFormatter.formatMinutes(sheet.totalMinutesWorked),
                  subLabel: 'از ${sheet.targetHours}:00 موظفی',
                  icon: Icons.schedule,
                  valueColor: theme.colorScheme.primary,
                  onTap: onTapTargetSettings,
                ),
              ),
              Container(
                height: 44,
                width: 1,
                color: theme.colorScheme.outlineVariant,
              ),
              Expanded(
                child: _MetricTile(
                  label: 'روزهای کارکرد',
                  value: '${sheet.totalDaysWorked} روز',
                  subLabel: sheet.incompleteDaysCount > 0
                      ? '${sheet.incompleteDaysCount} روز ناقص'
                      : 'از ${sheet.totalDaysInMonth} روز ماه',
                  icon: Icons.calendar_today,
                  valueColor: theme.colorScheme.onSurface,
                  onTap: onTapTargetSettings,
                ),
              ),
              Container(
                height: 44,
                width: 1,
                color: theme.colorScheme.outlineVariant,
              ),
              Expanded(
                child: _MetricTile(
                  label: isAhead ? 'اضافه‌کاری' : 'کسری کار',
                  value: TimeFormatter.formatMinutes(
                    balanceMins,
                    showSign: true,
                  ),
                  subLabel: isAhead ? 'بیشتر از موظفی' : 'کمتر از موظفی',
                  icon: isAhead ? Icons.trending_up : Icons.trending_down,
                  valueColor: isAhead
                      ? Colors.green.shade700
                      : theme.colorScheme.error,
                  onTap: onTapTargetSettings,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String subLabel;
  final IconData icon;
  final Color valueColor;
  final VoidCallback onTap;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.subLabel,
    required this.icon,
    required this.valueColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: valueColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: valueColor,
                    letterSpacing: 0.5,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              subLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// INDIVIDUAL DAY ROW CARD
// ============================================================================

class DayRowCard extends StatefulWidget {
  final DayEntry entry;
  final VoidCallback onChanged;

  const DayRowCard({
    super.key,
    required this.entry,
    required this.onChanged,
  });

  @override
  State<DayRowCard> createState() => _DayRowCardState();
}

class _DayRowCardState extends State<DayRowCard> {
  late TextEditingController _breakController;
  late TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _breakController = TextEditingController(
      text: widget.entry.breakMinutes > 0
          ? widget.entry.breakMinutes.toString()
          : '',
    );
    _noteController = TextEditingController(text: widget.entry.note);
  }

  @override
  void didUpdateWidget(covariant DayRowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBreakText = widget.entry.breakMinutes > 0
        ? widget.entry.breakMinutes.toString()
        : '';
    if (_breakController.text != newBreakText) {
      _breakController.text = newBreakText;
    }
    if (_noteController.text != widget.entry.note) {
      _noteController.text = widget.entry.note;
    }
  }

  @override
  void dispose() {
    _breakController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickTime({required bool isCheckIn}) async {
    final currentStr =
        isCheckIn ? widget.entry.checkIn : widget.entry.checkOut;
    final initialTime = TimeFormatter.parseTimeOfDay(currentStr) ??
        (isCheckIn
            ? const TimeOfDay(hour: 8, minute: 0)
            : const TimeOfDay(hour: 16, minute: 0));

    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: isCheckIn
          ? 'انتخاب ساعت ورود (روز ${widget.entry.dayNumber})'
          : 'انتخاب ساعت خروج (روز ${widget.entry.dayNumber})',
      cancelText: 'انصراف',
      confirmText: 'تایید',
      builder: (context, child) {
        // Force 24-hour format regardless of phone locale settings
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        if (isCheckIn) {
          widget.entry.checkIn = TimeFormatter.formatTimeOfDay(picked);
        } else {
          widget.entry.checkOut = TimeFormatter.formatTimeOfDay(picked);
        }
      });
      widget.onChanged();
    }
  }

  void _clearDay() {
    setState(() {
      widget.entry.checkIn = null;
      widget.entry.checkOut = null;
      widget.entry.breakMinutes = 0;
      widget.entry.note = '';
      _breakController.clear();
      _noteController.clear();
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = widget.entry.status;

    // Visual Cues: Subtle Green for complete, Amber for incomplete, Gray for empty
    Color cardBgColor;
    Color borderColor;
    Color badgeColor;

    switch (status) {
      case DayStatus.complete:
        cardBgColor = isDark
            ? Colors.green.shade900.withOpacity(0.22)
            : Colors.green.shade50;
        borderColor = isDark ? Colors.green.shade700 : Colors.green.shade300;
        badgeColor = isDark ? Colors.green.shade400 : Colors.green.shade700;
        break;
      case DayStatus.incomplete:
        cardBgColor = isDark
            ? Colors.amber.shade900.withOpacity(0.22)
            : Colors.amber.shade50;
        borderColor = isDark ? Colors.amber.shade700 : Colors.amber.shade400;
        badgeColor = isDark ? Colors.amber.shade400 : Colors.amber.shade800;
        break;
      case DayStatus.empty:
        cardBgColor = isDark
            ? Colors.grey.shade900.withOpacity(0.4)
            : Colors.grey.shade100;
        borderColor = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
        badgeColor = isDark ? Colors.grey.shade500 : Colors.grey.shade600;
        break;
    }

    return Card(
      elevation: 0,
      color: cardBgColor,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: borderColor, width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          children: [
            // TOP ROW: Day Badge, Check-In Button, Check-Out Button, Net Duration Badge
            Row(
              children: [
                // Day Number Badge
                Container(
                  width: 54,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: badgeColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: badgeColor.withOpacity(0.4)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'روز',
                        style: TextStyle(
                          fontSize: 10,
                          color: badgeColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${widget.entry.dayNumber}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: badgeColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Check-In Time Picker Button
                Expanded(
                  child: _TimePickerBox(
                    label: 'ساعت ورود',
                    timeValue: widget.entry.checkIn,
                    icon: Icons.login,
                    onTap: () => _pickTime(isCheckIn: true),
                  ),
                ),
                const SizedBox(width: 6),

                // Check-Out Time Picker Button
                Expanded(
                  child: _TimePickerBox(
                    label: 'ساعت خروج',
                    timeValue: widget.entry.checkOut,
                    icon: Icons.logout,
                    onTap: () => _pickTime(isCheckIn: false),
                  ),
                ),
                const SizedBox(width: 8),

                // Net Worked Duration Display
                Container(
                  constraints: const BoxConstraints(minWidth: 68),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: status == DayStatus.complete
                        ? badgeColor.withOpacity(0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'کارکرد خالص',
                            style: TextStyle(
                              fontSize: 10,
                              color: badgeColor,
                            ),
                          ),
                          if (widget.entry.isOvernightShift) ...[
                            const SizedBox(width: 2),
                            Tooltip(
                              message: 'شیفت شب (عبور از نیمه‌شب)',
                              child: Icon(
                                Icons.nights_stay,
                                size: 12,
                                color: badgeColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status == DayStatus.complete
                            ? widget.entry.formattedNetDuration
                            : status == DayStatus.incomplete
                                ? 'ناقص'
                                : '--:--',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: badgeColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // BOTTOM ROW: Break Deduction (Minutes), Note/Project Field, Clear Button
            Row(
              children: [
                // Break Deduction Input
                SizedBox(
                  width: 118,
                  child: TextField(
                    controller: _breakController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'کسر استراحت (دقیقه)',
                      labelStyle: const TextStyle(fontSize: 11),
                      prefixIcon:
                          const Icon(Icons.free_breakfast_outlined, size: 16),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onChanged: (val) {
                      setState(() {
                        widget.entry.breakMinutes = int.tryParse(val) ?? 0;
                      });
                      widget.onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 8),

                // Note / Project Name Input
                Expanded(
                  child: TextField(
                    controller: _noteController,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'توضیح / نام پروژه',
                      labelStyle: const TextStyle(fontSize: 11),
                      prefixIcon: const Icon(Icons.notes, size: 16),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onChanged: (val) {
                      widget.entry.note = val;
                      widget.onChanged();
                    },
                  ),
                ),

                // Clear Row Button (visible if row has any data)
                if (status != DayStatus.empty ||
                    widget.entry.breakMinutes > 0 ||
                    widget.entry.note.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'پاک کردن اطلاعات این روز',
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: _clearDay,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimePickerBox extends StatelessWidget {
  final String label;
  final String? timeValue;
  final IconData icon;
  final VoidCallback onTap;

  const _TimePickerBox({
    required this.label,
    required this.timeValue,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = timeValue != null && timeValue!.isNotEmpty;
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: colorScheme.surface.withOpacity(0.85),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hasValue
                ? colorScheme.primary.withOpacity(0.5)
                : colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 12, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              hasValue ? timeValue! : 'انتخاب',
              style: TextStyle(
                fontSize: 14,
                fontWeight: hasValue ? FontWeight.bold : FontWeight.normal,
                color: hasValue
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
