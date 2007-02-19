require 'mkmf'
CONFIG['CC'] = "g++"
$LDFLAGS += "-module"
create_, ldflags, _ = pkg_config 'utilmm'
$LDFLAGS << ldflags.gsub('-L', ' -Wl,-rpath -Wl,')
create_makefile("bgl")

