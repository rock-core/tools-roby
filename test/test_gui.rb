require 'roby/test/self'
require 'roby/log/gui/relations'

class TC_GUI < Minitest::Test 
    def test_index_handling
        model = Ui::RelationConfigModel.new(nil)
        [-1, 0, 222].each do |id|
            idx = model.createIndex(0, 0, id)
            assert_equal(id, Ui::RelationConfigModel.category_from_index(idx))
        end
    end
end


