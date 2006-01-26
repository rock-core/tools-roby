require 'test_config'
require 'test/unit'
require 'roby/adapters/genom'

class TC_Genom < Test::Unit::TestCase
    include Roby
    def test_def
        model = Genom::GenomModule('mockup')
        assert_nothing_raised { Roby::Genom::Mockup }
        assert_nothing_raised { Roby::Genom::Mockup::Start }
        assert_raises(NameError) { Roby::Genom::Mockup::SetIndex }
    end
end

