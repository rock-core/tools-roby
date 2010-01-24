# The main planner. A planner of this model is automatically added in the
# Interface planner list.
class MainPlanner < Roby::Planning::Planner
    method(:navigation, :returns => Services::Navigation)
    method(:localization, :returns => Services::Localization)

    method(:localization, :id => 'test') do
	Services::Localization.new(:id => 'localization')
    end
    method(:localization, :id => 'another') do
	Services::Localization.new(:id => 'another_localization')
    end

    method(:navigation, :id => 'test') do
	root = Services::Navigation.new
	root.depends_on(loc = localization)
	root
    end
end

