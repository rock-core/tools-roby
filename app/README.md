# App Folder Structure

An app configuration can be split in so-called `robot` configurations. Robot
configuration files are stored in `config/robots/`, and the list of files in that
directory defines which robots are available in a given app. New robots can be generated with

```
roby gen myrobot
```

A basic Roby application has the following directories:

config:: configuration files. config/init.rb is the main configuration file (loaded
	by all robots). Robot-specific configuration is in config/robots/ROBOTNAME.rb.
	The main Roby configuration file is config/roby.yml. The default file
  describes all available configuration options.
lib:: helper, non-Roby, code
models:: where the models are defined. Models are segregated per type (tasks,
  …) and robot (e.g. models/tasks/myrobot/* contains the task models for the
  myrobot robot)
scripts:: helper scripts
test:: test files

Use `roby gen` to create new models or robot configuration files. Running the
command without further arguments shows which generators are available, and
then adding `--help` provides detailed help for a given generator, e.g. `roby
gen robot --help`

