if RUBY_VERSION >= "1.9"
    STDERR.puts <<-EOB
The stable version of Roby is not compatible with 1.9. If you really want to
try it on 1.9, checkout the 1.9 branch of the development repository on github
(see README.txt for URLs)
    EOB
    exit(1)
end

module Roby
    VERSION = '0.7.3'
    ROBY_LIB_DIR  = File.expand_path( File.join(File.dirname(__FILE__), '..') )
    ROBY_ROOT_DIR = File.expand_path( File.join(ROBY_LIB_DIR, '..') )
end
