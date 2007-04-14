require 'roby'
require 'roby/app'
require 'test/unit'
r = Test::Unit::AutoRunner.new(true)
r.filters << lambda do |t|
    t.class != Roby::Test::TestCase
end

r.process_args(ARGV) or
  abort r.options.banner + " tests..."
exit r.run

