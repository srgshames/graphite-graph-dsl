require 'typhoeus'
require 'yajl'
# A small DSL to assist in the creation of Graphite graphs
# see https://github.com/ripienaar/graphite-graph-dsl/wiki
# for full details
class GraphiteGraphGenerator

  def initialize(graphite_base, directory, graph_gen_file_name, info={})
    @graphite_metrics_url = [graphite_base, "/metrics/index.json"].join
    @graphs_dir = directory
    @graph_gen_file = File.join(directory, graph_gen_file_name)
    @info = info
    
    @stats = []
    @properties = {}
    @general_text = ""
    @all_metrics = ""

    clean_old_generated_graphs
    load_graph_gen
    generate_graph_definitions
  end

  def load_graph_gen
    self.instance_eval(File.read(@graph_gen_file)) unless @graph_gen_file == :none
  end

  def generator(options)
    %w(context stats naming_pattern).each do |option|
      raise "field_gen needs a #{option}" unless options.include?(option.to_sym)
    end

    options.each do |key, value|
      self.instance_variable_set "@#{key}", value
    end
  end

  def method_missing(method, *args)
    @general_text << "#{method} "
    @general_text << ( args[0].is_a?(Symbol) ? ":#{args[0]}" : "\"#{args[0]}\"" )
    if args.length > 1
      @general_text << ",\n#{args[1].to_s[1..-2]}\n"
    end
    @general_text << "\n\n"
  end

  def clean_old_generated_graphs
    Dir.entries(@graphs_dir).select{|f| fn = File.join(@graphs_dir, f); File.delete(fn) if f.match(/gen.*\.graph$/)}
  end

  def generate_graph_definitions
    extract_all_metrics
    metric_branches.each do |branch|
      graph_name = extract_graph_name(branch)
      graph_file_name = "gen_#{graph_name}.graph"
      File.open(File.join(@graphs_dir, graph_file_name), 'w') {|f| f.write(graph_file_content(graph_name, branch)) }
    end
  end

  def extract_graph_name(branch)
    name_match = branch.match(@naming_pattern)
    name_match ? name_match.captures.join('.') : branch
  end

  def extract_all_metrics
    response = Typhoeus::Request.get(@graphite_metrics_url)
    raise "Error fetching #{@graphite_metrics_url}. #{response.inspect}" unless response.success?
    @all_metrics = Yajl::Parser.parse(response.body).join('|')
  end

  def metric_branches
    branches = @all_metrics.scan(@context).uniq.map { |branch| branch[0] }
  end

  def graph_file_content(graph_name, branch)
    graph_title = graph_name.gsub('_', ' ').gsub(' - ', ' ').gsub('.', ' - ').gsub('  ', ' ')      
    graph_file_content = "title \"#{graph_title}\"\n\n" << @general_text      
    @stats.each do |stat, property_overrides|
      if @all_metrics.match([branch, stat].join('.'))
        field_name = "#{stat}".gsub('.', '_')
        graph_file_content << "field :#{field_name},\n" << ":data => \"#{full_metric(branch, stat)}\""
        stat_properties = @properties
        stat_properties.update(property_overrides)
        if stat_properties.length > 0
          graph_file_content << ",\n#{stat_properties.to_s[1..-2]}\n"
        end
      end
      graph_file_content << "\n\n"
    end
    graph_file_content
  end
  
  def full_metric(branch, stat)
    full_metric = [branch, stat].join('.')
    full_metric = @target_wrapper % full_metric if @target_wrapper 
    full_metric
  end
end
