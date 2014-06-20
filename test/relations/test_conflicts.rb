require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/relations/conflicts'

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
	# should postpone start until t1 is stopped
	t2.start!
	assert(!t2.running?)
	assert t1.event(:stop).child_object?(t2.event(:start), Roby::EventStructure::Signal)
	t1.stop!
	assert(!t1.running?)
	assert(t2.running?)
    end
end

