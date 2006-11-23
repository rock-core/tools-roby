require 'mkmf'
CONFIG['CC'] = "g++"
$LDFLAGS += "-module"
dir_config('utilmm')
create_makefile("bgl")

