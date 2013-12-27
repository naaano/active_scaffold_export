module ActiveScaffold::Actions
  module Export
    def self.included(base)
      base.before_filter :export_authorized?, :only => [:export]
      base.before_filter :show_export_authorized?, :only => [:show_export]
      base.before_filter :init_session_var
    end

    def init_session_var
      session[:search] = params[:search] if !params[:search].nil? || params[:commit] == as_('Search')
    end

    # display the customization form or skip directly to export
    def show_export
      @export_config = active_scaffold_config.export
      respond_to do |wants|
        wants.html do
          render(:partial => 'show_export', :layout => true)
        end
        wants.js do
          render(:partial => 'show_export', :layout => false)
        end
      end
    end

    # if invoked directly, will use default configuration
    def export
      export_config = active_scaffold_config.export
      if params[:export_columns].nil?
        export_columns = {}
        export_config.columns.each { |col|
          export_columns[col.name.to_sym] = 1
        }
        options = {
          :export_columns => export_columns,
          :full_download => export_config.default_full_download.to_s,
          :delimiter => export_config.default_delimiter,
          :skip_header => export_config.default_skip_header.to_s
        }
        params.merge!(options)
      end

      @export_columns = export_config.columns.reject { |col| params[:export_columns][col.name.to_sym].nil? }
      includes_for_export_columns = @export_columns.collect{ |col| col.includes }.flatten.uniq.compact
      self.active_scaffold_includes.concat includes_for_export_columns
      @export_config = export_config
      # Make sure active_scaffold's find_page is dealing with the same list of
      # columns. Prevents an invalid SQL query when exporting after filtering
      # with field_search against a relation column, and that relation column is
      # not included in the set of export columns.
      @list_columns = @export_columns

      # this is required if you want this to work with IE
      if request.env['HTTP_USER_AGENT'] =~ /msie/i
        response.headers['Pragma'] = "public"
        response.headers['Cache-Control'] = "no-cache, must-revalidate, post-check=0, pre-check=0"
        response.headers['Expires'] = "0"
      end
      response.headers['Content-Disposition'] = "attachment; filename=#{export_file_name}"

      unless defined? Mime::XLSX
        Mime::Type.register "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :xlsx
      end

      respond_to do |format|
        format.csv do
          response.headers['Content-type'] = 'text/csv'
          # start streaming output
          self.response_body = Enumerator.new do |y|
            find_items_for_export do |records|
              @records = records
              str = render_to_string :partial => 'export', :layout => false, :formats => [:csv]
              y << str
              params[:skip_header] = 'true' # skip header on the next run
            end
          end
        end
        format.xlsx do 
          response.headers['Content-type'] = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          p = Axlsx::Package.new
          header = p.workbook.styles.add_style sz: 11, b: true,:bg_color => "69B5EF", :fg_color => "FF", alignment: { horizontal: :center }
          p.workbook.add_worksheet(name: active_scaffold_config.label) do |sheet|
            sheet.add_row(@export_columns.collect { |column| view_context.format_export_column_header_name(column) }, style: header) unless params[:skip_header]
            find_items_for_export do |records|
              records.each do |record|
                sheet.add_row @export_columns.collect{|column| view_context.get_export_column_value(record, column, false)}
              end
            end
          end
          stream = p.to_stream # when adding rows to sheet, they won't pass to this stream if declared before. axlsx issue?
          self.response_body = Enumerator.new do |y|
            y << stream.read 
          end
        end

      end
    end

    protected
    # The actual algorithm to do the export
    def find_items_for_export(&block)
      find_options = { :sorting =>
        active_scaffold_config.list.user.sorting.nil? ?
          active_scaffold_config.list.sorting : active_scaffold_config.list.user.sorting,
        :pagination => true
      }
      params[:search] = session[:search]
      do_search rescue nil
      params[:segment_id] = session[:segment_id]
      do_segment_search rescue nil

      if params[:full_download] == 'true'
        find_options.merge!({
          :per_page => 3000,
          :page => 1
        })
        find_page(find_options).pager.each do |page|
          yield page.items
        end
      else
        find_options.merge!({
          :pagination => active_scaffold_config.list.pagination,
          :per_page => active_scaffold_config.list.user.per_page,
          :page => active_scaffold_config.list.user.page
        })
        yield find_page(find_options).items
      end
    end

    # The default name of the downloaded file.
    # You may override the method to specify your own file name generation.
    def export_file_name
      filename = self.controller_name.clone

      if params[:format]
        if params[:format].to_sym == :xlsx
          filename << '.xlsx'
        elsif params[:format].to_sym == :csv
          filename << '.csv'
        end
      else
        filename << ".#{active_scaffold_config.export.default_file_format}"
      end

      return filename
    end

    # The default security delegates to ActiveRecordPermissions.
    # You may override the method to customize.
    def export_authorized?
      authorized_for?(:action => :read)
    end

    def show_export_authorized?
      export_authorized?
    end

  end
end
