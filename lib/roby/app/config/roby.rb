require 'roby'

require 'yaml'
require 'fileutils'
require 'tempfile'

$LOAD_PATH.unshift APP_DIR
ROBY_DIR = File.expand_path( File.join(File.dirname(__FILE__), '..') )

DISCOVERY = {}
LOG     = { 'timings' => false, 'events' => false, 'levels' => Hash.new }
CONTROL = { 'abort_on_exception' => false, 'abort_on_application_exception' => true, 'control_gc' => false }
DROBY   = { 'period' => 0.5, 'max_errors' => 1 }
TERRAIN = {}
ROBY_COMPONENTS = []

if defined? ROBOT && !defined? NAME
    NAME = ROBOT
end

# We expect here that both APP_DIR and ROBOT are set
conffile = File.join(APP_DIR, 'config', 'roby.yml')
all_conf = YAML.load(File.open(conffile))

discovery, terrain = nil
DISCOVERY.merge! discovery if discovery = all_conf['discovery']
TERRAIN.merge! terrain if terrain = all_conf['terrain']
if defined? NAME
    log, control, droby = nil
    LOG.merge! log         if log     = all_conf['log']
    CONTROL.merge! control if control = all_conf['control']
    DROBY.merge! droby     if droby   = all_conf['droby']

    if robot_conf = all_conf[NAME.to_s]
	LOG.merge! log         if log     = robot_conf['log']
	CONTROL.merge! control if control = robot_conf['control']
	DROBY.merge! droby     if droby   = robot_conf['droby']
    end
end

def find_data(name)
    Roby::State.datadirs.each do |dir|
	path = File.join(dir, name)
	return path if File.exists?(path)
    end
    raise Errno::ENOENT, "no such file #{path}"
end

def RobySetup
    # Set up log levels
    LOG['levels'].each do |name, value|
	if (mod = constant(name) rescue nil)
	    mod.logger.level = Logger.const_get(value)
	end
    end

    # Require all common task models
    task_dir = File.join(APP_DIR, 'tasks')
    Dir.new(task_dir).each do |task_file|
	task_file = File.expand_path(task_file, task_dir)
	require task_file if task_file =~ /\.rb$/ && File.file?(task_file)
    end

    # Set up some directories
    logdir = File.join(APP_DIR, 'log')
    if !File.exists?(logdir)
	Dir.mkdir(logdir)
    end
    Roby::State.datadirs = []
    datadir = File.join(APP_DIR, "data")
    if File.directory?(datadir)
	Roby::State.datadirs << datadir
    end

    # Load robot-specific configuration
    require File.join(APP_DIR, 'config', "#{ROBOT}.rb")

    require 'roby/planning'
    ROBY_COMPONENTS.map! { |c| c.to_s }
    ROBY_COMPONENTS.each { |c| require "roby/#{c}" }

    # Load the main planner definitions
    planner_dir = File.join(APP_DIR, 'planners')
    robot_planner_dir = File.join(planner_dir, ROBOT)
    robot_planner_dir = nil unless File.directory?(robot_planner_dir)

    # First, load the main planner
    require "planners/main"
    if robot_planner_dir
	begin
	    require "#{robot_planner_dir}/main"
	rescue LoadError => e
	    raise unless e.message =~ /no such file to load -- #{robot_planner_dir}\/main/
	end
    end

    # Load the other planners
    [robot_planner_dir, planner_dir].compact.each do |base_dir|
	Dir.new(base_dir).each do |file|
	    if File.file?(file) && file =~ /\.rb$/
		require file
	    end
	end
    end

    ROBY_COMPONENTS.each do |component|
	begin
	    require "roby/app/config/#{component}"
	rescue LoadError
	end
    end

    # Set filters for subsystem selection
    MainPlanner.class_eval do
	Roby::State.services.each_member do |name, value|
	    if value.respond_to?(:mode)
		filter(name) do |options, method|
		    options[:id] || method.id == value.mode
		end
	    end
	end
    end

    # MainPlanner is always included in the planner list
    Roby::Control.instance.planners << MainPlanner
end

def component_enabled?(name)
    ROBY_COMPONENTS.include?(name)
end

def RobyInit
    RobySetup()

    # Initialize dRoby
    if component_enabled?('distributed') && DROBY['host']
	DRb.start_service "roby://#{DROBY['host']}"
	droby_config = { :ring_discovery => !!DISCOVERY['ring'],
	    :name => NAME, :plan => Roby::Control.instance.plan, :max_allowed_errors => DROBY['max_errors'], :period => DROBY['period'] }

	if DISCOVERY['tuplespace']
	    droby_config[:discovery_tuplespace] = DRbObject.new_with_uri("roby://#{DISCOVERY['tuplespace']}")
	end
	Roby::Distributed.state = Roby::Distributed::ConnectionSpace.new(droby_config)

	if DISCOVERY['ring']
	    Roby::Distributed.publish DISCOVERY['ring']
	end
	Roby::Control.event_processing << Roby::Distributed.state.method(:start_neighbour_discovery)
    end

    # Start control
    control = Roby::Control.instance
    options = { :detach => true, :control_gc => false }
    if LOG['timings']
	logfile = File.join(APP_DIR, 'log', "#{NAME}-timings.log")
	options[:log] = File.open(logfile, 'w')
    end
    if LOG['events']
	require 'roby/log/file'
	logfile = File.join(APP_DIR, 'log', "#{NAME}-events.log")
	Roby::Log.loggers << Roby::Log::FileLogger.new(File.open(logfile, 'w'))
    end
    control.abort_on_exception = CONTROL['abort_on_exception']
    control.abort_on_application_exception = CONTROL['abort_on_application_exception']

    control.run options
end

