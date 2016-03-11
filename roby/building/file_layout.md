---
title: Creating a Roby App - File Layout
keywords: roby, robotics, rock, framework, ide
permalink: "/building/file_layout/"
---

Creating a new application
--------------------------
New Roby applications are created by going into a new folder and running

~~~ ruby
roby init
~~~

Search paths: robot name and robot type
---------------------------------
The configuration of the Roby application can be parametrized by a robot name
and a robot type. If only a single name is given, it is used for both.

These names influence Roby's loading sequence by either adding folders in the
search path or parametrizing the file that Roby is looking for.

File layout
-----------
This section gives an overview of a Roby application's file layout. You will be
reminded in the rest of the documentation, when it applies, to where certain
parts of the application should be stored.

config/
: configuration files. The files that are relevant for Roby are: app.yml,
  init.rb and files named like robots (e.g. ROBOT_NAME.rb and ROBOT_TYPE.rb)

models/
: contain definition of models. There are two standard subdirectories, 'tasks'
  for the [task models](task_models.html) and actions/ for the [action interface
  and action libraries](actions.html)

scripts/
: additional scripts useful to manage / maintain the app. The controllers/
  subfolder has a special meaning for running roby controllers. More on that
  [later](interacting/run.html)

data/
: non-code and non-model files that are relevant for the application

lib/
: additional library files (i.e. generic, non-roby-specific files). It gets
  added to the load path automatically

logs/
: where the log files are going. See [this
page](tutorial/relations_display.html) for a description.

Loading sequence
----------------
This section will describe which files are loaded in which order. The ROBOT_NAME
and ROBOT_TYPE placeholders are used in place of robot name and robot type.  Any
file or folder that is not found is simply ignored.

config/init.rb
: first file loaded

models/tasks,models/tasks/ROBOT_TYPE,models/tasks/ROBOT_NAME
: loading of task models. All three folders are searched for

models/actions/main.rb,models/actions/ROBOT_TYPE/main.rb,models/actions/ROBOT_NAME/main.rb
: loading of action models. Only the most specific file gets loaded.

config/ROBOT_TYPE.rb,config/ROBOT_NAME.rb
: loading of the robot's configuration file. Only the most specific file gets
  loaded.

