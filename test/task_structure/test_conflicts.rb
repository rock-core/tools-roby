require 'roby/test/self'
require 'roby/tasks/simple'

class TC_Conflicts < Minitest::Test
    def test_model_relations
	m1, m2 = (1..2).map do
	    Tasks::Simple.new_submodel
	end

	m1.conflicts_with m2
	assert(!m1.conflicts_with?(m1))
	assert(m1.conflicts_with?(m2))
	assert(m2.conflicts_with?(m1))

	# Create two tasks ...
	plan.add(t1 = m1.new)
	plan.add(t2 = m2.new)
	assert !t1.child_object?(t2, Roby::TaskStructure::Conflicts)
	assert !t2.child_object?(t1, Roby::TaskStructure::Conflicts)

	# Start t1 ...
	t1.start!
	assert !t1.child_object?(t2, Roby::TaskStructure::Conflicts)
	assert t2.child_object?(t1, Roby::TaskStructure::Conflicts)

	# And now, start the conflicting task. The default decision control
	# calls failed_to_start
        assert_raises(UnreachableEvent) do
            t2.start!
        end
        assert t2.failed_to_start?
    end
end

