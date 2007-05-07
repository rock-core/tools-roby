== Directories
A basic Roby application has the following directories:
config:: configuration files. config/init.rb is the main configuration file (loaded
	 by all robots). Robot-specific configuration is in config/ROBOTNAME.rb.
	 The main Roby configuration file is config/roby.yml. The default file
         describes all available configuration options.
planners:: planner models. Global planners (shared by all robots) are in
	   planners/. Robot-specific planners are in planners/ROBOTNAME/
controllers:: robot controllers. These files are supposed to start the basic robot
	      services, to make the robot ready. A robot shall have a controllers/ROBOTNAME.rb
	      file which does that.
tasks:: task models
data:: where all data files are. See #find_data.
scripts:: various scripts needed to run and debug a Roby application

The basic directory structure, and the global files, are installed by <tt>roby init</tt>. Basic
robot files can be added by <tt>roby robot ROBOTNAME</tt>

== Genom/Pocosim integration
An application can use the Genom/Pocosim integration by calling <tt>roby init --module genom</tt>.
The following files and directories are added:
config/ROBOTNAME-genom.rb:: Genom-specific configuration for ROBOTNAME
tasks/genom/:: per-Genom module tasks

