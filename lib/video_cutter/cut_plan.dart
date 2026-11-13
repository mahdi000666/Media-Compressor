typedef VideoSection = ({Duration start, Duration end});

enum CutMode { removeSections, exportClips }

String cutOutputName(String basename, CutMode mode) =>
    '${basename}_${mode == CutMode.removeSections ? 'Cut' : 'Clip'}.mp4';

List<VideoSection> orderedSections(
  Iterable<VideoSection> sections,
  Duration duration,
) {
  final ordered = sections.toList()..sort((a, b) => a.start.compareTo(b.start));
  var previousEnd = Duration.zero;
  for (final section in ordered) {
    if (section.start < previousEnd ||
        section.start.isNegative ||
        section.end <= section.start ||
        section.end > duration) {
      throw ArgumentError(
        'Sections must be within the video, have an end after their start, and not overlap.',
      );
    }
    previousEnd = section.end;
  }
  return List.unmodifiable(ordered);
}

List<List<VideoSection>> planCuts(
  Iterable<VideoSection> sections,
  Duration duration,
  CutMode mode,
) {
  final ordered = orderedSections(sections, duration);
  if (ordered.isEmpty) throw ArgumentError('Add a section first.');
  if (mode == CutMode.exportClips) {
    return [
      for (final section in ordered) [section],
    ];
  }
  final kept = <VideoSection>[];
  var cursor = Duration.zero;
  for (final section in ordered) {
    if (section.start > cursor) kept.add((start: cursor, end: section.start));
    cursor = section.end;
  }
  if (cursor < duration) kept.add((start: cursor, end: duration));
  if (kept.isEmpty) {
    throw ArgumentError('Removing these sections would leave no video.');
  }
  return [kept];
}

String sectionTime(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  final milliseconds = (value.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$hours:$minutes:$seconds.$milliseconds';
}
