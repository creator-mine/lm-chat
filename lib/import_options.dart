/// What the import dialog should add to the current history.
class ImportOptions {
  const ImportOptions({
    this.includeServers = true,
    this.includeTemplates = true,
    this.includeArchived = true,
    this.skipExisting = false,
  });

  /// Import servers and their settings (tokens are always stripped).
  final bool includeServers;

  /// Import prompt templates.
  final bool includeTemplates;

  /// Keep archived chats from the file.
  final bool includeArchived;

  /// Skip chats whose IDs already exist instead of creating copies.
  final bool skipExisting;

  ImportOptions copyWith({
    bool? includeServers,
    bool? includeTemplates,
    bool? includeArchived,
    bool? skipExisting,
  }) => ImportOptions(
    includeServers: includeServers ?? this.includeServers,
    includeTemplates: includeTemplates ?? this.includeTemplates,
    includeArchived: includeArchived ?? this.includeArchived,
    skipExisting: skipExisting ?? this.skipExisting,
  );
}
