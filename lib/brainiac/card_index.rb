# frozen_string_literal: true

# CardIndex — duplicate card detection via trigram string similarity + qmd semantic search.
#
# Two detection layers run in parallel:
#   1. Trigram similarity — fast, catches near-identical titles ("Fix login bug" ≈ "Fix login bug on mobile")
#   2. qmd vsearch — semantic embeddings, catches same-meaning different-words
#      ("Login page broken on mobile" ≈ "Users can't sign in from phones")
#
# Results are merged by card number, keeping the higher score from either method.
#
# Only the local machine's creator cards are checked for duplicates (creator-based
# routing prevents multi-machine races).

require "json"
require "open3"
require "fileutils"
require "yaml"

class CardIndex
  SIMILARITY_THRESHOLD = 0.65
  SEMANTIC_THRESHOLD = 0.65
  SEMANTIC_COLLECTION = "card-titles"
  QMD_DEBOUNCE = 30 # seconds

  attr_reader :index_file, :titles_dir

  def initialize(index_file:, titles_dir:)
    @index_file = index_file
    @titles_dir = titles_dir
    @data = {}
    @mutex = Mutex.new
    @qmd_mutex = Mutex.new
    @qmd_last_run = nil
    @qmd_pending = false
  end

  # --- Hash-like access (thread-safe) ---

  def [](key)
    @mutex.synchronize { @data[key] }
  end

  def []=(key, value)
    @mutex.synchronize { @data[key] = value }
  end

  def delete(key)
    @mutex.synchronize { @data.delete(key) }
  end

  def size
    @mutex.synchronize { @data.size }
  end

  def key?(key)
    @mutex.synchronize { @data.key?(key) }
  end

  def each(&)
    @mutex.synchronize { @data.each(&) }
  end

  def dig(*keys)
    @mutex.synchronize { @data.dig(*keys) }
  end

  def to_json(...)
    @mutex.synchronize { @data.to_json(...) }
  end

  def to_h
    @mutex.synchronize { @data.dup }
  end

  # --- Trigram similarity ---

  def trigrams(str)
    normalized = str.downcase.gsub(/[^a-z0-9\s]/, "").strip
    return Set.new if normalized.length < 3

    Set.new((0..(normalized.length - 3)).map { |i| normalized[i, 3] })
  end

  def trigram_similarity(str_a, str_b)
    ta = trigrams(str_a)
    tb = trigrams(str_b)
    return 0.0 if ta.empty? || tb.empty?

    intersection = (ta & tb).size.to_f
    union = (ta | tb).size.to_f
    intersection / union
  end

  # --- Card title files for qmd collection ---

  def sync_card_title_file(number, title, closed: false)
    FileUtils.mkdir_p(@titles_dir)
    path = File.join(@titles_dir, "#{number}.md")
    if closed
      FileUtils.rm_f(path)
    else
      File.write(path, title)
    end
  end

  def remove_card_title_file(number)
    FileUtils.rm_f(File.join(@titles_dir, "#{number}.md"))
  end

  # Ensure the qmd collection exists, create if not
  def ensure_card_titles_collection
    FileUtils.mkdir_p(@titles_dir)
    output, _, status = Open3.capture3("qmd", "collection", "list")
    return if status.success? && output.include?(SEMANTIC_COLLECTION)

    LOG.info "[CardIndex] Creating qmd collection '#{SEMANTIC_COLLECTION}'"
    _, stderr, s = Open3.capture3("qmd", "collection", "add", @titles_dir,
                                  "--name", SEMANTIC_COLLECTION, "--mask", "*.md")
    LOG.warn "[CardIndex] Failed to create qmd collection: #{stderr}" unless s.success?
  end

  # Debounced qmd update + embed. Runs in background thread.
  def schedule_qmd_reindex
    @qmd_mutex.synchronize do
      @qmd_pending = true
      return if @qmd_last_run && (Time.now - @qmd_last_run) < QMD_DEBOUNCE

      @qmd_last_run = Time.now
      @qmd_pending = false
    end

    Thread.new do
      LOG.info "[CardIndex] Running qmd update for card titles..."
      _, stderr, s = Open3.capture3("qmd", "update")
      LOG.warn "[CardIndex] qmd update failed: #{stderr}" unless s.success?

      LOG.info "[CardIndex] Running qmd embed for card titles..."
      _, stderr, s = Open3.capture3("qmd", "embed")
      LOG.warn "[CardIndex] qmd embed failed: #{stderr}" unless s.success?

      LOG.info "[CardIndex] qmd reindex complete"

      needs_rerun = @qmd_mutex.synchronize do
        if @qmd_pending
          @qmd_pending = false
          @qmd_last_run = Time.now
          true
        else
          false
        end
      end
      schedule_qmd_reindex if needs_rerun
    rescue StandardError => e
      LOG.warn "[CardIndex] qmd reindex failed: #{e.message}"
    end
  end

  # --- Index operations ---

  def load
    data = if File.exist?(@index_file)
             JSON.parse(File.read(@index_file))
           else
             {}
           end
    @mutex.synchronize { @data.replace(data) }
    LOG.info "[CardIndex] Loaded #{size} cards from disk"
  rescue JSON::ParserError => e
    LOG.error "Failed to parse card index: #{e.message}"
    @mutex.synchronize { @data.replace({}) }
  end

  def save
    @mutex.synchronize do
      File.write(@index_file, JSON.generate(@data))
    end
  end

  def index_card(number:, title:, creator_name: nil, creator_id: nil, tags: [], closed: false)
    @mutex.synchronize do
      @data[number.to_s] = {
        "title" => title,
        "creator_name" => creator_name,
        "creator_id" => creator_id,
        "tags" => tags.map { |t| t.is_a?(Hash) ? t["name"] : t.to_s },
        "closed" => closed,
        "indexed_at" => Time.now.iso8601
      }
    end
    sync_card_title_file(number, title, closed: closed)
  end

  def evict_card(number)
    delete(number.to_s)
    remove_card_title_file(number)
  end

  # --- Scope extraction for cross-project duplicate filtering ---

  def build_scope_map
    return if @scope_map_built

    @scope_map ||= {}
    PROJECTS.each do |key, cfg|
      (cfg["fizzy_tags"] || []).each { |t| @scope_map[t.downcase] = key }
      (cfg["scope_tags"] || {}).each { |tag, scope| @scope_map[tag.downcase] = scope }
    end
    @scope_map_built = true
  end

  def card_scopes(tags)
    return Set.new if tags.nil? || tags.empty?

    build_scope_map
    tag_names = tags.map { |t| (t.is_a?(Hash) ? t["name"] : t).to_s.downcase }
    scopes = Set.new
    tag_names.each { |t| scopes << @scope_map[t] if @scope_map[t] }
    scopes
  end

  def different_scopes?(tags_a, tags_b)
    scopes_a = card_scopes(tags_a)
    scopes_b = card_scopes(tags_b)
    scopes_a.any? && scopes_b.any? && !scopes_a.intersect?(scopes_b)
  end

  # --- Trigram search ---

  def find_trigram_similar_cards(title, exclude_number: nil)
    matches = []
    each do |num, entry|
      next if num == exclude_number.to_s
      next if entry["closed"]

      score = trigram_similarity(title, entry["title"])
      matches << { number: num.to_i, title: entry["title"], score: score, method: :trigram } if score >= SIMILARITY_THRESHOLD
    end
    matches
  end

  # --- Semantic search via qmd vsearch ---

  def find_semantic_similar_cards(title, exclude_number: nil)
    output, stderr, status = Open3.capture3("qmd", "vsearch", title, "-c", SEMANTIC_COLLECTION,
                                            "--json", "--min-score", SEMANTIC_THRESHOLD.to_s, "--all")
    unless status.success?
      LOG.warn "[CardIndex] qmd vsearch failed: #{stderr.lines.last&.strip}"
      return []
    end

    clean = output.lines.reject { |l| l.start_with?("[node-llama-cpp]") }.join
    json_start = clean.index("[")
    return [] unless json_start

    results = JSON.parse(clean[json_start..])
    results.filter_map do |r|
      num = r["file"]&.match(%r{/(\d+)\.md$})&.[](1)
      next unless num
      next if num == exclude_number.to_s

      entry = self[num]
      next if entry&.dig("closed")

      { number: num.to_i, title: entry&.dig("title") || r["snippet"]&.strip || "", score: r["score"], method: :semantic }
    end
  rescue JSON::ParserError => e
    LOG.warn "[CardIndex] Failed to parse qmd vsearch output: #{e.message}"
    []
  end

  # --- Merged search: trigram + semantic in parallel ---

  def find_similar_cards(title, exclude_number: nil, tags: nil)
    trigram_thread = Thread.new { find_trigram_similar_cards(title, exclude_number: exclude_number) }
    semantic_thread = Thread.new { find_semantic_similar_cards(title, exclude_number: exclude_number) }

    trigram_results = trigram_thread.value
    semantic_results = semantic_thread.value

    merged = {}
    (trigram_results + semantic_results).each do |match|
      key = match[:number]
      existing = merged[key]
      if existing.nil? || match[:score] > existing[:score]
        merged[key] = match
      elsif match[:score] == existing[:score] && existing[:method] != match[:method]
        merged[key] = existing.merge(method: :both)
      end
    end

    if tags && card_scopes(tags).any?
      merged.reject! do |num, _match|
        match_tags = dig(num.to_s, "tags")
        different_scopes?(tags, match_tags)
      end
    end

    merged.values.sort_by { |m| -m[:score] }
  end

  # --- Backfill from Fizzy API on startup ---

  def backfill
    Thread.new do
      LOG.info "[CardIndex] Starting backfill from Fizzy API..."
      backfilled = 0
      seen_boards = Set.new

      PROJECTS.each do |project_key, config|
        result = backfill_project(project_key, config, seen_boards)
        backfilled += result if result
      end

      save
      LOG.info "[CardIndex] Backfill complete: #{backfilled} new cards indexed (#{size} total)"

      ensure_card_titles_collection
      schedule_qmd_reindex
    end
  end

  # Backfill cards for a single project. Returns count of new cards indexed, or nil if skipped.
  def backfill_project(project_key, config, seen_boards)
    repo_path = config["repo_path"]
    return nil unless repo_path && File.directory?(repo_path)

    fizzy_yaml = File.join(repo_path, ".fizzy.yaml")
    unless File.exist?(fizzy_yaml)
      LOG.debug "[CardIndex] Skipping '#{project_key}' — no .fizzy.yaml"
      return nil
    end

    begin
      board_id = YAML.safe_load_file(fizzy_yaml)["board"]
    rescue StandardError => e
      LOG.warn "[CardIndex] Could not read .fizzy.yaml for '#{project_key}': #{e.message}"
      return nil
    end

    if seen_boards.include?(board_id)
      LOG.debug "[CardIndex] Skipping '#{project_key}' — board #{board_id} already fetched"
      return nil
    end
    seen_boards << board_id

    count = 0
    output = run_cmd("fizzy", "card", "list", "--all", chdir: repo_path, env: default_fizzy_env)
    cards = JSON.parse(output)["data"] || []
    cards.each do |card|
      num = card["number"]
      next unless num
      next if key?(num.to_s)

      index_card(
        number: num,
        title: card["title"] || card["description"]&.slice(0, 80) || "untitled",
        creator_name: card.dig("creator", "name"),
        creator_id: card.dig("creator", "id"),
        tags: card["tags"] || [],
        closed: card["closed"] || false
      )
      count += 1
    end
    count
  rescue StandardError => e
    LOG.warn "[CardIndex] Backfill failed for project '#{project_key}': #{e.message}"
    0
  end

  # --- Startup ---

  def sync_title_files
    FileUtils.mkdir_p(@titles_dir)
    each do |num, entry|
      sync_card_title_file(num, entry["title"], closed: entry["closed"])
    end
  end
end

# --- Create singleton instance ---

CARD_INDEX = CardIndex.new(
  index_file: File.join(BRAINIAC_DIR, "card_index.json"),
  titles_dir: File.join(BRAINIAC_DIR, "card_titles")
)

CARD_INDEX.load
CARD_INDEX.sync_title_files
