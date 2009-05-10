$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'roby/test/tasks/empty_task'

require 'roby/log/gui/relations'

class TC_Task < Test::Unit::TestCase 
    include Roby::Test

    def test_index_handling
        model = Ui::RelationConfigModel.new(nil)
        [-1, 0, 222].each do |id|
            idx = model.createIndex(0, 0, id)
            assert_equal(id, Ui::RelationConfigModel.category_from_index(idx))
        end
    end
end


