#include <stddef.h>
#include <errno.h>
/* iOS cannot spawn a shell. Keep the standard Lua libraries otherwise intact.
 * Do not define LUA_USE_IOS: upstream enables dlopen and POSIX popen with it. */
#define l_system(cmd) ((cmd) == NULL ? 0 : (errno = ENOSYS, -1))
