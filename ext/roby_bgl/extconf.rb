require 'mkmf'
CONFIG['CC'] = "g++"
dir_config 'boost'
$CFLAGS += " -O3"
#$LDFLAGS += " -module"

create_makefile("roby_bgl")

