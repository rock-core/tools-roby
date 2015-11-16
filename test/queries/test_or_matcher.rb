require 'roby/test/self'
require 'roby/tasks/simple'

class TC_Queries_OrMatcher < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

    def test_it_should_be_marshallable_through_droby
        verify_is_droby_marshallable_object(TaskMatcher.with_arguments(id: 1) | TaskMatcher.with_arguments(id: 2))
    end

    def test_it_should_allow_to_combine_matchers
	t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
	t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
	t3 = Roby::Task.new
	plan.add [t1, t2, t3]

        query = (TaskMatcher.with_arguments(id: 1) | TaskMatcher.with_arguments(id: 2))
        assert_equal [t1, t2].to_set, query.each(plan).to_set
    end
end


