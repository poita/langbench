/// Fixed parameters of the Tessera format (SPEC §5.2).
module tessera.constants;

enum PAGE_SIZE = 1024;
enum MAX_KEY = 128;
enum MAX_INDEX_KEY = 128;
enum MAX_INLINE = 192;
enum OVF_PAYLOAD = 1012;
enum BTREE_HEADER = 16;
enum CAPACITY = 1008;
enum MIN_FILL = 336;
enum MAX_INDEXES = 16;
enum MAX_PATH = 30;
enum MAX_PATH_SEGMENTS = 8;
enum WAL_LIMIT = 262_144;
enum MAX_LIMIT = 2_147_483_647;
