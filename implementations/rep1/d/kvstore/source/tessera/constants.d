/// Format constants of the Tessera store. Every value is fixed by the format
/// specification; none is configurable.
module tessera.constants;

enum size_t pageSize = 1024;       /// bytes per page
enum size_t maxKey = 128;          /// maximum primary key length in bytes
enum size_t maxIndexKey = 128;     /// maximum index key length in bytes
enum size_t maxInline = 192;       /// document bytes held in a primary leaf cell
enum size_t overflowPayload = 1012;/// document bytes held in one overflow page
enum size_t maxDoc = 65_536;       /// maximum serialised document length
enum int maxDepth = 32;            /// maximum value nesting depth
enum size_t nodeHeader = 16;       /// bytes of header on a B+tree page
enum size_t pageCapacity = 1008;       /// payload bytes available on a B+tree page
enum size_t minFill = 336;         /// underflow threshold for deletions
enum size_t maxIndexes = 16;       /// directory slots for secondary indexes
enum size_t maxPath = 30;          /// maximum field-path text length in bytes
enum size_t maxPathSegments = 8;   /// maximum number of segments in a path
enum size_t walLimit = 262_144;    /// log size that triggers a checkpoint
enum long maxLimit = 2_147_483_647;/// largest accepted `limit` argument
enum size_t walHeaderSize = 32;    /// bytes in the log header
enum size_t walRecordHeader = 24;  /// bytes in a log record header

/// Page type bytes.
enum ubyte typeFree = 0, typePrimaryLeaf = 1, typeInterior = 2,
           typeOverflow = 3, typeIndexLeaf = 5;
