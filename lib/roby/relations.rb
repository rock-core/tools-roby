require 'roby/support'

module Roby
    # Base support for relations. It is mixed-in objects that are
    # part of relation networks (like Task and EventGenerator)
    # It is used by the DirectedRelation module, which is used
    # to define the relation modules (like TaskSupport::Hierarchy)
    module DirectedRelationSupport
	# A type -> parent map
	attribute(:parents) do Hash.new { |h, k| h[k] = Set.new } end
	# A type -> children map
	attribute(:children) do Hash.new { |h, k| h[k] = Hash.new } end

	def each_parent_object(type = nil, &iterator)
	    enum_for(:apply_selection, parents, :each_key, type).
		map { |type| parents[type].to_enum }.
		inject { |enum, new_enum| enum + new_enum }.
		enum_uniq { |obj| obj }.
		each(&iterator)
	end
	def each_child_object(type = nil)
	    enum_for(:apply_selection, children, :each_key, type).
		map { |type| children[type].to_enum }.
		inject { |enum, new_enum| enum + new_enum }.
		enum_uniq { |obj| obj }.
		each { |child, _| yield(child) }
	end

	def child_object?(obj, type = nil)
	    enum_for(:apply_selection, children, :each_key, type).
		find { |type| children[type].has_key?(obj) }
	end
	def parent_object?(obj, type = nil)
	    enum_for(:apply_selection, parents, :each_key, type).
		find { |type| parents[type].include?(obj) }
	end
	def related_object?(obj); child_object?(obj) || parent_object?(obj) end


	# Enumerate all relations this object is part of.
	# If directed is false, then we enumerate both parents
	# and children.
	def each_relation(directed = false) # :yield: type, parent, child
	    children.each do |type, set|
		set.each do |child, info|
		    yield(type, self, child, info)
		end
	    end

	    if !directed
		parents.each do |type, set|
		    set.each do |parent|
			yield(type, parent, self, parent.children[type][self])
		    end
		end
	    end
	end

	# Add a new relation
	def add_child(to, type, info = nil)
	    to.parents[type] << self
	    children[type][to] = info
	end

	# Remove relations
	def remove_child(to = nil, type = nil)
	    apply_selection(children, :each_key, type) do |type|
		apply_selection(children[type], :each_key, to) do |to|
		    to.parents[type].delete(self)
		    children[type].delete(to)
		end
	    end
	end

	def apply_selection(container, enumerator, object, &iterator)
	    if object
		yield(object)
	    else
		container.send(enumerator, &iterator)
	    end
	end
	private :apply_selection
    end

    module DirectedRelation
	# Defines the enumerators for this relationship. It defines each_#{parent}
	# and each_#{child}
	def enumerators(parent, child)
	    relation_type = self
	    enumerator = "enumerate_#{name.gsub(':', '_').underscore}"
	    if parent
		define_method("#{enumerator}_parents") { |iterator| parents[relation_type].each(&iterator) }
		class_eval "def each_#{parent}(&iterator); #{enumerator}_parents(iterator) end"
	    end
	    if child
		define_method("#{enumerator}_children") { |iterator| children[relation_type].each { |child, _| iterator[child] } }
		class_eval "def each_#{child}(&iterator); #{enumerator}_children(iterator) end"
	    end
	end
    end

    class Task
	include DirectedRelationSupport
    end
    class EventGenerator
	include DirectedRelationSupport
    end
    
    module TaskStructure
	def self.const_missing(name)
	    TaskStructure.const_set(name, Module.new)
	end
	def self.task_relation(mod, &block)
	    mod.extend DirectedRelation
	    mod.class_eval(&block)

	    Task.include mod
	end
    end

    module EventStructure
	def self.const_missing(name)
	    EventStructure.const_set(name, Module.new)
	end
	def self.event_relation(mod, &block)
	    mod.extend DirectedRelation
	    mod.class_eval(&block)

	    EventGenerator.include mod
	end
    end
end

