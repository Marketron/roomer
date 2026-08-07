# require "active_record/connection_adapters/postgresql/schema_dumper"

module Roomer
  class SchemaDumper < ActiveRecord::ConnectionAdapters::SchemaDumper

    # Placeholder swapped into raw SQL before it's turned into a Ruby string
    # literal, then restored afterwards as a live #{} interpolation. Keeps
    # ActiveRecord::Base.table_name_prefix resolved at *load* time (when the
    # dumped file runs) rather than baked in as a fixed value at dump time.
    TABLE_NAME_PREFIX_MARKER = "__ROOMER_TABLE_NAME_PREFIX__"

    class << self
      def dump(connection = ActiveRecord::Base.connection, stream = STDOUT, config = ActiveRecord::Base)
        create(connection, generate_options(config)).dump(stream)
        # connection.create_schema_dumper(generate_options(config)).dump(stream)
        stream
      end

      private
        def generate_options(config)
          {
            table_name_prefix: config.table_name_prefix,
            table_name_suffix: config.table_name_suffix
          }
        end
    end

    def dump(stream)
      header(stream)
      extensions(stream)
      tables(stream)
      views(stream)
      triggers(stream)
      trailer(stream)
      stream
    end

    protected

    def header(stream)
      define_params = @version ? ":version => #{@version}" : ""
      stream.puts <<HEADER
# It's strongly recommended to check this file into your version control system.
    
Roomer::Schema.define(#{define_params}) do

HEADER
    end

    def views(stream)
      stream.puts <<VIEWS
  # Database Views
  # The following statements persist database views across tenants

VIEWS
      # Make sure search_path is public so schema name gets dumped
      # along with table names.
      current_schema = @connection.schema_search_path
      @connection.schema_search_path = "public"
      views = @connection.select_all(%{
        SELECT *
        FROM   pg_views
        WHERE  schemaname = '#{current_schema}';
      })
      # Reinstating previous search path to make sure nothing breaks
      @connection.schema_search_path = current_schema
      unless views.empty?
        views.each do |view|
          definition = view['definition'].gsub(/#{Regexp.escape(current_schema)}\./, TABLE_NAME_PREFIX_MARKER)
          sql = "CREATE OR REPLACE VIEW #{TABLE_NAME_PREFIX_MARKER}#{view['viewname']} AS #{definition}"
          stream.puts "  execute(#{ruby_literal_with_deferred_prefix(sql)})"
        end
      end
    end

    def triggers(stream)
      stream.puts <<TRIGGERS
  # Database Triggers
  # The following statements persist database triggers across tenants

TRIGGERS
      current_schema = @connection.schema_search_path
      @connection.schema_search_path = "public"
      triggers = @connection.select_all(%{
        SELECT
          n.nspname AS function_schema,
          p.proname AS function_name,
          l.lanname AS function_language,
          CASE
            WHEN l.lanname = 'internal'
              THEN p.prosrc
            ELSE pg_get_functiondef(p.oid)
          END AS definition,
          pg_get_function_arguments(p.oid) AS function_arguments,
          t.typname AS return_type
        FROM
          pg_proc p
          LEFT JOIN pg_namespace n ON p.pronamespace = n.oid
          LEFT JOIN pg_language l ON p.prolang = l.oid
          LEFT JOIN pg_type t ON t.oid = p.prorettype
        WHERE
          n.nspname = '#{current_schema}'
        AND CASE WHEN l.lanname = 'internal' THEN p.prosrc ELSE pg_get_functiondef(p.oid) END iLIKE '%trigger%';
      })
      # Reinstating previous search path to make sure nothing breaks
      @connection.schema_search_path = current_schema
      unless triggers.empty?
        triggers.each do |trigger|
          definition = trigger['definition'].gsub(/#{Regexp.escape(current_schema)}\./, TABLE_NAME_PREFIX_MARKER)
          stream.puts "  execute(#{ruby_literal_with_deferred_prefix(definition)})"
        end
      end

    end

    # Turns raw SQL into a safely-escaped Ruby string literal, preserving any
    # TABLE_NAME_PREFIX_MARKER occurrences as a live #{} interpolation so the
    # dumped file re-evaluates table_name_prefix when it's loaded, instead of
    # embedding raw SQL text (which can contain unescaped quotes) directly
    # inside a hand-rolled double-quoted string.
    def ruby_literal_with_deferred_prefix(sql)
      sql.inspect.gsub(TABLE_NAME_PREFIX_MARKER, '#{ActiveRecord::Base.table_name_prefix}')
    end

    #Extensions to deal new postgres functionality
    def extensions(stream)
      extensions = @connection.extensions
      if extensions.any?
        stream.puts "  # These are extensions that must be enabled in order to support this database"
        extensions.sort.each do |extension|
          stream.puts "  enable_extension #{extension.inspect}"
        end
        stream.puts
      end
    end

    def roomer_index_name(index_name)
      sections = index_name.split(".")
      if sections.length > 1
        if sections[0].split("_")[0] == "index"
          sections[0] = "index"
        end
      end
      sections.join(".")
    end

    def indexes_in_create(table, stream)
      # do nothing here to prevent duplicate index statements
    end

    def indexes(table, stream)
      if (indexes = @connection.indexes(table)).any?
        add_index_statements = indexes.map do |index|
          statement_parts = [ ('add_index ' + index.table.inspect) ]
          statement_parts << index.columns.inspect

          statement_parts << (':name => "' + roomer_index_name(index.name) + '"')
          statement_parts << ':unique => true' if index.unique
          statement_parts << "order: #{format_index_parts(index.orders)}" if index.orders.present?
          statement_parts << "opclass: #{format_index_parts(index.opclasses)}" if index.opclasses.present?
          statement_parts << "where: #{index.where.inspect}" if index.where
          statement_parts << "using: #{index.using.inspect}" if !@connection.default_index_type?(index)
          statement_parts << "type: #{index.type.inspect}" if index.type
          statement_parts << "comment: #{index.comment.inspect}" if index.comment

          index_lengths = index.lengths.compact if index.lengths.is_a?(Array)
          if index_lengths.present?
            statement_parts << (':length => ' + Hash[*index.columns.zip(index.lengths).flatten].inspect)
          end

          '  ' + statement_parts.join(', ')
        end

        stream.puts add_index_statements.sort.join("\n")
        stream.puts
      end
    end
  end
end

