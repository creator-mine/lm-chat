/// What the user wants in an exported file.
///
/// Shared by the export sheet (UI) and [AppState] export helpers, so the same
/// options drive JSON, Markdown and the size hint.
enum ExportFormat { json, markdown }

/// Which chats to include.
enum ExportScope { allChats, currentChat }

class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.json,
    this.scope = ExportScope.allChats,
    this.includeServers = true,
    this.includeTemplates = true,
    this.includeAttachments = true,
    this.includeReasoning = true,
    this.includeStats = true,
    this.includeAttachmentNames = true,
    this.includeArchived = true,
  });

  final ExportFormat format;
  final ExportScope scope;

  /// JSON: servers and their settings (never tokens).
  final bool includeServers;

  /// JSON: prompt templates.
  final bool includeTemplates;

  /// JSON: image attachments as base64.
  final bool includeAttachments;

  /// Markdown: model reasoning blocks.
  final bool includeReasoning;

  /// Markdown: token and speed statistics.
  final bool includeStats;

  /// Markdown: image file names under user messages.
  final bool includeAttachmentNames;

  /// Both formats: archived chats in the "all chats" scope.
  final bool includeArchived;

  ExportOptions copyWith({
    ExportFormat? format,
    ExportScope? scope,
    bool? includeServers,
    bool? includeTemplates,
    bool? includeAttachments,
    bool? includeReasoning,
    bool? includeStats,
    bool? includeAttachmentNames,
    bool? includeArchived,
  }) => ExportOptions(
    format: format ?? this.format,
    scope: scope ?? this.scope,
    includeServers: includeServers ?? this.includeServers,
    includeTemplates: includeTemplates ?? this.includeTemplates,
    includeAttachments: includeAttachments ?? this.includeAttachments,
    includeReasoning: includeReasoning ?? this.includeReasoning,
    includeStats: includeStats ?? this.includeStats,
    includeAttachmentNames:
        includeAttachmentNames ?? this.includeAttachmentNames,
    includeArchived: includeArchived ?? this.includeArchived,
  );
}
