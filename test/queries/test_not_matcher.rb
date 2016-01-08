require 'roby/test/self'
require 'roby/tasks/simple'

class TC_Queries_NotMatcher < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

    def test_it_should_allow_to_combine_matchers
	t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
	t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
	t3 = Roby::Task.new
	plan.add [t1, t2, t3]

        query = (TaskMatcher.with_arguments(id: 1) | TaskMatcher.with_arguments(id: 2)).negate
        assert_equal [t3].to_set, query.each(plan).to_set
    end
end

