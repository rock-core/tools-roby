require 'roby'
require 'roby/app'
require 'test/unit'
r = Test::Unit::AutoRunner.new(true)
r.process_args(ARGV) or
  abort r.options.banner + " tests..."

if r.filters.empty?
    r.filters << lambda do |t|
	t.class != Roby::Test::TestCase
    end
end

exit r.run

