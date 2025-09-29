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
          key: unique_key,
          name: display_name,
          value: value.to_f.round(2),
          percentage: percentage.to_f.round(1),
          color: color
        }
        nodes.size - 1
      end
    }

    total_income_value = income_totals.total.to_f
    total_expense_value = expense_totals.total.to_f
     # Gather category aggregates
    category_totals = Hash.new { |h, k| h[k] = { category: nil, income: 0.0, expense: 0.0 } }
    uncategorized_income_total  = 0.0
    uncategorized_expense_total = 0.0
    uncategorized_income_meta   = { name: "Uncategorized", color: Category::COLORS.sample }
    uncategorized_expense_meta  = { name: "Uncategorized", color: Category::UNCATEGORIZED_COLOR }

    # ---------- Income Categories ----------
    income_totals.category_totals.each do |category_total|
      next if category_total.category.parent_id.present?
      total_value = category_total.total.to_f.round(2)
      next if total_value.zero?

      if category_total.category && category_total.category.name.to_s.strip.casecmp("Uncategorized").zero?
        uncategorized_income_total += total_value
        uncategorized_income_meta[:name]  = category_total.category.name if category_total.category&.name.present?
        uncategorized_income_meta[:color] = category_total.category.color if category_total.category&.color.present?
        next
      end

      entry = category_totals[category_total.category.id]
      entry[:category] ||= category_total.category
      entry[:income]   += total_value
    end

    # ---------- Expense Categories ----------
    expense_totals.category_totals.each do |category_total|
      next if category_total.category.parent_id.present?
      total_value = category_total.total.to_f.round(2)
      next if total_value.zero?

      if category_total.category && category_total.category.name.to_s.strip.casecmp("Uncategorized").zero?
        uncategorized_expense_total += total_value
        uncategorized_expense_meta[:name]  = category_total.category.name if category_total.category&.name.present?
        uncategorized_expense_meta[:color] = category_total.category.color if category_total.category&.color.present?
        next
      end

      entry = category_totals[category_total.category.id]
      entry[:category] ||= category_total.category
      entry[:expense]  += total_value
    end

    # ---------- Cash Flow Node ----------
    cash_flow_index = add_node.call(
      "cash_flow_node",
      "Cash Flow",
      total_income_value,
      0,
      "var(--color-success)"
    )

    # ---------- Net Per Category ----------
    category_totals.each_value do |entry|
      category = entry[:category]
      net_value = (entry[:income] - entry[:expense]).round(2)
      next if net_value.zero?

      category_color = category.color.presence || Category::COLORS.sample
      absolute_net_value = net_value.abs

      if net_value.positive?
        percentage = total_income_value.zero? ? 0 : (absolute_net_value / total_income_value * 100).round(1)
        category_index = add_node.call("net_#{category.id}", category.name, absolute_net_value, percentage, category_color)
        links << {
          source: category_index,
          target: cash_flow_index,
          value: absolute_net_value,
          color: category_color,
          percentage: percentage
        }
      else
        percentage = total_expense_value.zero? ? 0 : (absolute_net_value / total_expense_value * 100).round(1)
        category_index = add_node.call("net_#{category.id}", category.name, absolute_net_value, percentage, category_color)
        links << {
          source: cash_flow_index,
          target: category_index,
          value: absolute_net_value,
          color: category_color,
          percentage: percentage
        }
      end
    end

    # ---------- Uncategorized ----------
    if uncategorized_income_total.positive?
      percentage = total_income_value.zero? ? 0 : (uncategorized_income_total / total_income_value * 100).round(1)
      income_index = add_node.call(
        "income_uncategorized",
        uncategorized_income_meta[:name],
        uncategorized_income_total,
        percentage,
        uncategorized_income_meta[:color]
      )
      links << {
        source: income_index,
        target: cash_flow_index,
        value: uncategorized_income_total,
        color: uncategorized_income_meta[:color],
        percentage: percentage
      }
    end

    if uncategorized_expense_total.positive?
      percentage = total_expense_value.zero? ? 0 : (uncategorized_expense_total / total_expense_value * 100).round(1)
      expense_index = add_node.call(
        "expense_uncategorized",
        uncategorized_expense_meta[:name],
        uncategorized_expense_total,
        percentage,
        uncategorized_expense_meta[:color]
      )
      links << {
        source: cash_flow_index,
        target: expense_index,
        value: uncategorized_expense_total,
        color: uncategorized_expense_meta[:color],
        percentage: percentage
      }
    end

    # ---------- Surplus ----------
    leftover_value = (total_income_value - total_expense_value).round(2)
    if leftover_value.positive?
      percentage = total_income_value.zero? ? 0 : (leftover_value / total_income_value * 100).round(1)
      surplus_index = add_node.call(
        "surplus_node",
        "Surplus",
        leftover_value,
        percentage,
        "var(--color-success)"
      )
      links << {
        source: cash_flow_index,
        target: surplus_index,
        value: leftover_value,
        color: "var(--color-success)",
        percentage: percentage
      }
    end

    # ---------- Node Sorting ----------
    nodes_sorted = nodes.sort_by do |node|
      case node[:key]
      when "cash_flow_node"
        [0, 0]
      when /uncategorized/
        [2, -node[:value]]
      when "surplus_node"
        [3, -node[:value]]
      else
        [1, -node[:value]]
      end
    end

    key_to_new_index = {}
    nodes_sorted.each_with_index do |node, i|
      key_to_new_index[node[:key]] = i
    end

    links.each do |link|
      link[:source] = key_to_new_index[nodes[link[:source]][:key]]
      link[:target] = key_to_new_index[nodes[link[:target]][:key]]
    end

    if key_to_new_index["cash_flow_node"]
      nodes_sorted[key_to_new_index["cash_flow_node"]][:percentage] = 100.0
    end

    {
      nodes: nodes_sorted,
      links: links,
      currency_symbol: Money::Currency.new(currency_symbol).symbol
    }
  end
end
