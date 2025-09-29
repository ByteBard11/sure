class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  def dashboard
    @balance_sheet = Current.family.balance_sheet
    @accounts = Current.family.accounts.visible.with_attached_logo

    period_param = params[:cashflow_period]
    @cashflow_period = if period_param.present?
      begin
        Period.from_key(period_param)
      rescue Period::InvalidKeyError
        Period.last_30_days
      end
    else
      Period.last_30_days
    end

    family_currency = Current.family.currency
    income_totals = Current.family.income_statement.income_totals(period: @cashflow_period)
    expense_totals = Current.family.income_statement.expense_totals(period: @cashflow_period)

    @cashflow_sankey_data = build_cashflow_sankey_data(income_totals, expense_totals, family_currency)

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: "Release notes unavailable",
        published_at: Date.current,
        body: "<p>Unable to fetch the latest release notes at this time. Please check back later or visit our <a href='https://github.com/we-promise/sure/releases' target='_blank'>GitHub releases page</a> directly.</p>"
      }
    end

    render layout: "settings"
  end

  def feedback
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  private
    def github_provider
      Provider::Registry.get_provider(:github)
    end

  def build_cashflow_sankey_data(income_totals, expense_totals, currency_symbol)
    nodes = []
    links = []
    node_indices = {} # Memoize node indices by a unique key: "type_categoryid"

    # Helper to add/find node and return its index
    add_node = ->(unique_key, display_name, value, percentage, color) {
      node_indices[unique_key] ||= begin
        nodes << {
          key: unique_key, # keep key for index remapping later
          name: display_name,
          value: value.to_f.round(2),
          percentage: percentage.to_f.round(1),
          color: color
        }
        nodes.size - 1
      end
    }

    # Helper to detect "Uncategorized"
    is_uncategorized = ->(cat) do
      return false unless cat
      (cat.respond_to?(:uncategorized?) && cat.uncategorized?) ||
        cat.name.to_s.strip.casecmp("uncategorized").zero? ||
        cat.name.to_s.strip.casecmp("uncategorised").zero?
    end

    total_income_val = income_totals.total.to_f.round(2)
    total_expense_val = expense_totals.total.to_f.round(2)

    # Gather category aggregates
    by_cat = Hash.new { |h, k| h[k] = { category: nil, income: 0.0, expense: 0.0 } }
    uncat_income_total  = 0.0
    uncat_expense_total = 0.0
    uncat_income_meta   = { name: "Uncategorized", color: Category::COLORS.sample }
    uncat_expense_meta  = { name: "Uncategorized", color: Category::UNCATEGORIZED_COLOR }

    # Income side
    income_totals.category_totals.each do |ct|
      next if ct.category.parent_id.present?
      val = ct.total.to_f.round(2)
      next if val.zero?

      if is_uncategorized.call(ct.category)
        uncat_income_total += val
        uncat_income_meta[:name]  = ct.category.name if ct.category&.name.present?
        uncat_income_meta[:color] = ct.category.color if ct.category&.color.present?
        next
      end

      entry = by_cat[ct.category.id]
      entry[:category] ||= ct.category
      entry[:income] += val
    end

    # Expense side
    expense_totals.category_totals.each do |ct|
      next if ct.category.parent_id.present?
      val = ct.total.to_f.round(2)
      next if val.zero?

      if is_uncategorized.call(ct.category)
        uncat_expense_total += val
        uncat_expense_meta[:name]  = ct.category.name if ct.category&.name.present?
        uncat_expense_meta[:color] = ct.category.color if ct.category&.color.present?
        next
      end

      entry = by_cat[ct.category.id]
      entry[:category] ||= ct.category
      entry[:expense] += val
    end

    # --- Create Central Cash Flow Node ---
    cash_flow_idx = add_node.call(
      "cash_flow_node",
      "Cash Flow",
      total_income_val,
      0,
      "var(--color-success)"
    )

    # --- Process Net Per Category (excluding Uncategorized) ---
    by_cat.each_value do |entry|
      cat = entry[:category]
      net = (entry[:income] - entry[:expense]).round(2)
      next if net.zero?

      node_color = cat.color.presence || Category::COLORS.sample
      net_abs = net.abs

      if net.positive?
        perc = total_income_val.zero? ? 0 : (net_abs / total_income_val * 100).round(1)
        idx = add_node.call("net_#{cat.id}", cat.name, net_abs, perc, node_color)
        links << {
          source: idx,
          target: cash_flow_idx,
          value: net_abs,
          color: node_color,
          percentage: perc
        }
      else
        perc = total_expense_val.zero? ? 0 : (net_abs / total_expense_val * 100).round(1)
        idx = add_node.call("net_#{cat.id}", cat.name, net_abs, perc, node_color)
        links << {
          source: cash_flow_idx,
          target: idx,
          value: net_abs,
          color: node_color,
          percentage: perc
        }
      end
    end

    # --- Keep Uncategorized separate ---
    if uncat_income_total.positive?
      perc = total_income_val.zero? ? 0 : (uncat_income_total / total_income_val * 100).round(1)
      idx = add_node.call(
        "income_uncategorized",
        uncat_income_meta[:name],
        uncat_income_total,
        perc,
        uncat_income_meta[:color]
      )
      links << {
        source: idx,
        target: cash_flow_idx,
        value: uncat_income_total,
        color: uncat_income_meta[:color],
        percentage: perc
      }
    end

    if uncat_expense_total.positive?
      perc = total_expense_val.zero? ? 0 : (uncat_expense_total / total_expense_val * 100).round(1)
      idx = add_node.call(
        "expense_uncategorized",
        uncat_expense_meta[:name],
        uncat_expense_total,
        perc,
        uncat_expense_meta[:color]
      )
      links << {
        source: cash_flow_idx,
        target: idx,
        value: uncat_expense_total,
        color: uncat_expense_meta[:color],
        percentage: perc
      }
    end

    # --- Process Surplus ---
    leftover = (total_income_val - total_expense_val).round(2)
    if leftover.positive?
      perc = total_income_val.zero? ? 0 : (leftover / total_income_val * 100).round(1)
      surplus_idx = add_node.call(
        "surplus_node",
        "Surplus",
        leftover,
        perc,
        "var(--color-success)"
      )
      links << {
        source: cash_flow_idx,
        target: surplus_idx,
        value: leftover,
        color: "var(--color-success)",
        percentage: perc
      }
    end

    # --- Sorting of nodes ---
    # Cash Flow stays at top, Uncategorized next, Surplus last
    nodes_sorted = nodes.sort_by do |n|
      if n[:key] == "cash_flow_node"
        [0, 0] # force first
      elsif n[:key].to_s.include?("uncategorized")
        [2, n[:value] * -1] # after others, group by value
      elsif n[:key] == "surplus_node"
        [3, n[:value] * -1] # very last
      else
        [1, -n[:value]] # normal categories sorted by descending value
      end
    end

    # Reassign indices based on new ordering
    key_to_new_idx = {}
    nodes_sorted.each_with_index do |n, i|
      key_to_new_idx[n[:key]] = i
    end
    links.each do |l|
      l[:source] = key_to_new_idx[nodes[l[:source]][:key]]
      l[:target] = key_to_new_idx[nodes[l[:target]][:key]]
    end
    nodes = nodes_sorted

    # --- Fix Cash Flow percentage ---
    if key_to_new_idx["cash_flow_node"]
      nodes[key_to_new_idx["cash_flow_node"]][:percentage] = 100.0
    end

    { nodes: nodes,
      links: links,
      currency_symbol: Money::Currency.new(currency_symbol).symbol }
  end
end
