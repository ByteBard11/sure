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
    node_indices = {}

    add_node = ->(unique_key, display_name, value, percentage, color) {
      node_indices[unique_key] ||= begin
        nodes << {
          name: display_name,
          value: value.to_f.round(2),
          percentage: percentage.to_f.round(1),
          color: color
        }
        nodes.size - 1
      end
    }

    total_income_val = income_totals.total.to_f.round(2)
    total_expense_val = expense_totals.total.to_f.round(2)

    # --- Create Central Cash Flow Node ---
    cash_flow_idx = add_node.call(
      "cash_flow_node",
      "Cash Flow",
      total_income_val,
      0,
      "var(--color-success)"
    )

    # --- Combine income + expenses per category ---
    net_by_cat = Hash.new { |h, k| h[k] = 0.0 }
    cats = {}

    income_totals.category_totals.each do |ct|
      next if ct.category.parent_id.present?
      net_by_cat[ct.category.id] += ct.total.to_f
      cats[ct.category.id] ||= ct.category
    end

    expense_totals.category_totals.each do |ct|
      next if ct.category.parent_id.present?
      net_by_cat[ct.category.id] -= ct.total.to_f
      cats[ct.category.id] ||= ct.category
    end

    total_net_income = net_by_cat.values.select { |v| v > 0 }.sum.round(2)
    total_net_expense = net_by_cat.values.select { |v| v < 0 }.map(&:abs).sum.round(2)

    # --- Process combined categories ---
    net_by_cat.each do |cat_id, net_val|
      category = cats[cat_id]
      val = net_val.round(2)
      next if val.zero?

      if val > 0
        percentage = total_net_income.zero? ? 0 : (val / total_net_income * 100).round(1)
        node_color = category.color.presence || Category::COLORS.sample
        idx = add_node.call("income_#{cat_id}", category.name, val, percentage, node_color)
        links << { source: idx, target: cash_flow_idx, value: val, color: node_color, percentage: percentage }
      else
        positive_val = val.abs
        percentage = total_net_expense.zero? ? 0 : (positive_val / total_net_expense * 100).round(1)
        node_color = category.color.presence || Category::UNCATEGORIZED_COLOR
        idx = add_node.call("expense_#{cat_id}", category.name, positive_val, percentage, node_color)
        links << { source: cash_flow_idx, target: idx, value: positive_val, color: node_color, percentage: percentage }
      end
    end

    # --- Surplus ---
    leftover = (total_net_income - total_net_expense).round(2)
    if leftover.positive?
      percentage = total_net_income.zero? ? 0 : (leftover / total_net_income * 100).round(1)
      surplus_idx = add_node.call("surplus_node", "Surplus", leftover, percentage, "var(--color-success)")
      links << { source: cash_flow_idx, target: surplus_idx, value: leftover, color: "var(--color-success)", percentage: percentage }
    end

    # Update Cash Flow node %
    nodes[node_indices["cash_flow_node"]][:percentage] = 100.0 if node_indices["cash_flow_node"]

    {
      nodes: nodes,
      links: links,
      currency_symbol: Money::Currency.new(currency_symbol).symbol
    }
  end
end
