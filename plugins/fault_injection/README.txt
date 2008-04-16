= Fault injection plugin for Roby

http://rubyforge.org/projects/roby

== DESCRIPTION:

This is a fault injection plugin for the Roby robotic control framework. It
allows to test the management of rarely occuring events by simulating the
emission of those events.

== SYNOPSIS:

The fault injection plugin can be used in a system to inject some spurious
events randomly. To set it up, one must call Application#add_fault_model
in the configuration files of the application. For instance,

  Roby.app.add_fault_model P3d::Track,
        :no_path, :blocked,
        Roby::FaultInjection::Rate.new(500, 0.3)
  
Would inject events :no_path and :blocked randomly on any task of the P3d:Track
model. The probability distribution used is a rate distribution with MTTF of
500s and base probability of 0.3. See Roby::FaultInjection for the description
of the available probability distributions.

== REQUIREMENTS:

This plugin relies only on the core Roby library.

== INSTALL:

This plugin can be installed using 

  gem install roby-fault-injection

== LICENSE:

This work is licensed under the CeCiLL-B license, which is a free software
license similar to the BSD license. See License.txt for details.

