require 'roby/test/self'
require 'roby/tasks/simple'

class TC_Queries_AndMatcher < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

    def test_it_should_be_marshallable_through_droby
        verify_is_droby_marshallable_object(TaskMatcher.fully_instanciated & TaskMatcher.executable.with_arguments(:id => 1))
    end

    def test_it_should_allow_to_combine_matchers
	t1 = Tasks::Simple.new_submodel { argument :id }.new(:id => 1)
	t2 = Tasks::Simple.new_submodel { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan.add [t1, t2, t3]

        query = (TaskMatcher.fully_instanciated & TaskMatcher.executable)
        assert_equal [t1, t2].to_set, query.each(plan).to_set
        query = (TaskMatcher.fully_instanciated & TaskMatcher.executable.with_arguments(:id => 1))
        assert_equal [t1].to_set, query.each(plan).to_set
        query = (TaskMatcher.fully_instanciated & TaskMatcher.abstract)
        assert_equal [t3].to_set, query.each(plan).to_set
    end
end

