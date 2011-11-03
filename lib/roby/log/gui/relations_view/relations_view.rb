require 'roby/log/plan_rebuilder'
require 'roby/log/gui/plan_rebuilder_widget'
require 'roby/log/gui/object_info_view'
require 'roby/log/gui/relations_view/relations_view_ui'
require 'roby/log/gui/relations_view/relations_config'

module Roby
    module LogReplay
        module RelationsDisplay
            class RelationsView < PlanView
                attr_reader :ui

                attr_reader :plan_rebuilder
                attr_reader :view

                # In remote connections, this is he period between checking if
                # there is data on the socket, in seconds
                #
                # See #connect
                def initialize(parent = nil, plan_rebuilder = nil)
                    super(parent)
                    @ui = Ui::RelationsView.new
                    ui.setupUi(self)

                    ui.history.setContentsMargins(0, 0, 0, 0)
                    history_widget.setContentsMargins(0, 0, 0, 0)
                    history_widget.ui = ui
                    @history_widget_layout = Qt::VBoxLayout.new(ui.history)
                    @history_widget_layout.setContentsMargins(0, 0, 0, 0)
                    @history_widget_layout.add_widget(@history_widget)

                    @view = RelationsCanvas.new([@history_widget.current_plan])
                    history_widget.add_display(@view)
                    ui.setupActions(self)
                    ui.graphics.scene = view.scene

                    resize 500, 500
                end

                def info(message)
                    ui.info.setText(message)
                end

                def warn(message)
                    ui.info.setText("<font color=\"red\">#{message}</font>")
                end
            end
        end
    end
end


class Ui::RelationsView
    def scene; graphics.scene end

    # The underlying Roby::LogReplay::RelationsDisplay::RelationsCanvas object
    attr_reader :display
    attr_reader :prefixActions

    # Module used to extend the relation view GraphicsView object, to add
    # double-click and context-menu events
    module GraphicsViewBehaviour
        attr_accessor :display

        def mouseDoubleClickEvent(event)
            item = itemAt(event.pos)
            if item
                obj = display.object_of(item) ||
                    display.relation_of(item)

                if !obj
                    return super(event)
                end
            end

            @object_info ||= Roby::LogReplay::ObjectInfoView.new
            if @object_info.display(obj)
                @object_info.activate
            end
        end

        def contextMenuEvent(event)
            item = itemAt(event.pos)
            if item
                unless obj = display.object_of(item)
                    return super(event)
                end
            end

            return unless obj.kind_of?(Roby::LogReplay::RelationsDisplay::DisplayTask)

            menu = Qt::Menu.new
            hide_this     = menu.add_action("Hide")
            hide_children = menu.add_action("Hide children")
            show_children = menu.add_action("Show children")
            return unless action = menu.exec(event.globalPos)

            case action.text
            when "Hide"
                display.selected_objects.delete(obj)
            when "Hide children"
                for child in Roby::TaskStructure.children_of(obj, display.enabled_relations)
                    display.selected_objects.delete(child)
                end
            when "Show children"
                for child in Roby::TaskStructure.children_of(obj, display.enabled_relations)
                    display.selected_objects << child
                end
            end

            display.update
        end
    end

    ZOOM_STEP = 0.25
    def setupActions(view)
	@display   = display = view.view

        @actionShowAll = Qt::Action.new(view)
        @actionShowAll.objectName = "actionShowAll"
        @actionShowAll.text = "Show All"
        @actionRedraw = Qt::Action.new(view)
        @actionRedraw.objectName = "actionRedraw"
        @actionRedraw.text = "Redraw"
        @actionZoom = Qt::Action.new(view)
        @actionZoom.objectName = "actionZoom"
        @actionZoom.text = "Zoom +"
        @actionUnzoom = Qt::Action.new(view)
        @actionUnzoom.objectName = "actionUnzoom"
        @actionUnzoom.text = "Zoom -"
        @actionFit = Qt::Action.new(view)
        @actionFit.objectName = "actionFit"
        @actionFit.text = "Fit View"
        @actionOwnership = Qt::Action.new(view)
        @actionOwnership.objectName = "actionOwnership"
        @actionOwnership.text = "Display Ownership"
        @actionOwnership.checkable = true
        @actionOwnership.checked = true
        @actionSVGExport = Qt::Action.new(view)
        @actionSVGExport.objectName = "actionSVGExport"
        @actionSVGExport.text = "SVG Export"
        @actionPrint = Qt::Action.new(view)
        @actionPrint.objectName = "actionPrint"
        @actionPrint.text = "Print"
        @actionKeepSignals = Qt::Action.new(view)
        @actionKeepSignals.objectName = "actionKeepSignals"
        @actionKeepSignals.text = "Keep Signals"
        @actionKeepSignals.checkable = true
        @actionKeepSignals.checked = false
        @actionBookmarksAdd = Qt::Action.new(view)
        @actionBookmarksAdd.objectName = "actionBookmarksAdd"
        @actionBookmarksAdd.text = "Add Bookmark"
        @actionHideFinalized = Qt::Action.new(view)
        @actionHideFinalized.objectName = "actionHideFinalized"
        @actionHideFinalized.text = "Hide Finalized"
        @actionHideFinalized.checkable = true
        @actionHideFinalized.checked = true
        @actionConfigure = Qt::Action.new(view)
        @actionConfigure.objectName = "actionConfigure"
        @actionConfigure.text = "Configure"

        @menubar = Qt::MenuBar.new(view)
        @menubar.objectName = "menubar"
        @menubar.geometry = Qt::Rect.new(0, 0, 800, 21)
        @menuView = Qt::Menu.new("View", @menubar)
        @menuView.objectName = "menuView"

        @menubar.addAction(@menuView.menuAction())
        @menuView.addAction(@actionKeepSignals)
        @menuView.addAction(@actionShowAll)
        @menuView.addSeparator()
        @menuView.addAction(@actionZoom)
        @menuView.addAction(@actionUnzoom)
        @menuView.addAction(@actionFit)
        @menuView.addSeparator()
        @menuView.addAction(@actionSVGExport)
        @menuView.addAction(@actionPrint)
        @menuView.addAction(@actionConfigure)

        @verticalLayout_2.setMenuBar(@menubar)

        @actionConfigure.connect(SIGNAL(:triggered)) do
            if !@configuration_widget
                @configuration_widget = Qt::Widget.new
                @configuration_widget_ui = Ui::RelationsConfig.new(@configuration_widget, display)
            end
            @configuration_widget.show
        end
	
	#############################################################
	# Handle the other toolbar's buttons
	graphics.extend GraphicsViewBehaviour
        graphics.display = display

	@actionShowAll.connect(SIGNAL(:triggered)) do
	    display.graphics.keys.each do |obj|
		display.set_visibility(obj, true) if obj.kind_of?(Roby::Task::DRoby) || (obj.kind_of?(Roby::EventGenerator::DRoby) && !obj.respond_to?(:task))
	    end
	    display.update
	end

	@actionZoom.connect(SIGNAL(:triggered)) do 
	    scale = graphics.matrix.m11
	    if scale + ZOOM_STEP > 1
		scale = 1 - ZOOM_STEP
	    end
	    graphics.resetMatrix
	    graphics.scale scale + ZOOM_STEP, scale + ZOOM_STEP
	end
	@actionUnzoom.connect(SIGNAL(:triggered)) do
	    scale = graphics.matrix.m11
	    graphics.resetMatrix
	    graphics.scale scale - ZOOM_STEP, scale - ZOOM_STEP
	end
	@actionFit.connect(SIGNAL(:triggered)) do
	    graphics.fitInView(graphics.scene.items_bounding_rect, Qt::KeepAspectRatio)
	end

	@actionKeepSignals.connect(SIGNAL(:triggered)) do 
	    display.keep_signals = @actionKeepSignals.checked?
	end

	@actionPrint.connect(SIGNAL(:triggered)) do
	    return unless scene
	    printer = Qt::Printer.new;
	    if Qt::PrintDialog.new(printer).exec() == Qt::Dialog::Accepted
		painter = Qt::Painter.new(printer);
		painter.setRenderHint(Qt::Painter::Antialiasing);
		scene.render(painter);
	    end
	end

	@actionSVGExport.connect(SIGNAL(:triggered)) do
	    return unless scene

	    if path = Qt::FileDialog.get_save_file_name(nil, "SVG Export")
		svg = Qt::SvgGenerator.new
		svg.file_name = path
		svg.size = Qt::Size.new(Integer(scene.width * 0.8), Integer(scene.height * 0.8))
		painter = Qt::Painter.new
		painter.begin(svg)
		scene.render(painter)
		painter.end
	    end
	end
	@actionSVGExport.enabled = defined?(Qt::SvgGenerator)
    end
end

