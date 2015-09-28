require 'mkmf'

CONFIG['LDSHARED'].gsub! '$(CC)', "$(CXX)"
if try_link("int main() { }", "-module")
    $LDFLAGS += " -module"
end

create_makefile("value_set/value_set")

## WORKAROUND a problem with mkmf.rb
# It seems that the newest version do define an 'install' target. However, that
# install target tries to install in the system directories
#
# The issue is that RubyGems *does* call make install. Ergo, gem install utilrb
# is broken right now
#lines = File.readlines("Makefile")
#lines.delete_if { |l| l =~ /^install:/ }
#lines << "install:"
#File.open("Makefile", 'w') do |io|
#      io.write lines.join("\n")
#end

