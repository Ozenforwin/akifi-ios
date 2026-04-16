import type { TxRow, SupabaseClient } from './types.ts';

export type FinancialStage = 'beginner' | 'has_debt' | 'building_emergency' | 'saving' | 'investing' | 'fire';

export interface UserFinancialProfile {
  stage: FinancialStage;
  has_debts: boolean;
  has_emergency_fund: boolean;
  has_investments: boolean;
  monthly_income: number;
  monthly_expense: number;
  savings_rate: number;
}

/**
 * Detect user's financial stage from transaction data.
 * Called lazily — only for coaching intents.
 *
 * IMPORTANT: We NEVER auto-detect debts from category names — this causes
 * false positives. Debt stage is only set if user explicitly tells us.
 * Stage determination is based on: income/expense ratio, savings goals, account types.
 */
export async function detectFinancialStage(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
): Promise<UserFinancialProfile> {
  // Используем все переданные транзакции (index.ts уже ограничивает до 180 дней)
  const recentTx = transactions;

  const totalIncome = recentTx
    .filter((t) => t.type === 'income' && !t.transfer_group_id)
    .reduce((s, t) => s + Math.abs(t.amount), 0);

  const totalExpense = recentTx
    .filter((t) => t.type === 'expense' && !t.transfer_group_id)
    .reduce((s, t) => s + Math.abs(t.amount), 0);

  // Count unique months with data for accurate averaging
  const monthsWithData = new Set(recentTx.map((t) => t.date.slice(0, 7))).size;
  const divisor = Math.max(1, monthsWithData);

  const monthlyIncome = totalIncome / divisor;
  const monthlyExpense = totalExpense / divisor;
  const savingsRate = monthlyIncome > 0 ? Math.max(0, (monthlyIncome - monthlyExpense) / monthlyIncome) : 0;

  // Check for savings goals (emergency fund indicator)
  let hasEmergencyFund = false;
  try {
    const { data: goals } = await serviceClient
      .from('savings_goals')
      .select('id,current_amount,target_amount,status')
      .eq('user_id', userId)
      .eq('status', 'active')
      .limit(10);

    if (goals && goals.length > 0) {
      hasEmergencyFund = goals.some(
        (g: { current_amount: number; target_amount: number }) =>
          g.target_amount > 0 && g.current_amount / g.target_amount >= 0.5,
      );
    }
  } catch {
    // savings_goals may not exist
  }

  // Check for investment-like accounts (ByBit, broker accounts, etc.)
  let hasInvestments = false;
  try {
    const { data: accounts } = await serviceClient
      .from('accounts')
      .select('name')
      .eq('user_id', userId)
      .limit(50);

    const investmentAccountKeywords = ['bybit', 'binance', 'брокер', 'инвестиц', 'тинькофф инвест', 'etf', 'акци', 'крипт'];
    if (accounts) {
      hasInvestments = accounts.some(
        (a: { name: string }) => investmentAccountKeywords.some((kw) => a.name.toLowerCase().includes(kw)),
      );
    }
  } catch {
    // accounts table issue
  }

  // If not detected by accounts, check transaction categories
  if (!hasInvestments) {
    const investmentCatKeywords = ['инвестиц', 'акци', 'etf', 'облигаци', 'брокер', 'фонд', 'крипт'];
    hasInvestments = recentTx.some((t) => {
      const catName = (t.category?.name ?? '').toLowerCase();
      return investmentCatKeywords.some((kw) => catName.includes(kw));
    });
  }

  // Determine stage (NEVER auto-assign has_debt — only from explicit user input)
  let stage: FinancialStage = 'beginner';

  if (recentTx.length === 0) {
    stage = 'beginner';
  } else if (savingsRate < 0.05 && !hasEmergencyFund) {
    stage = 'building_emergency';
  } else if (hasInvestments) {
    stage = savingsRate >= 0.4 ? 'fire' : 'investing';
  } else if (hasEmergencyFund || savingsRate >= 0.1) {
    stage = 'saving';
  } else {
    stage = 'building_emergency';
  }

  const profile: UserFinancialProfile = {
    stage,
    has_debts: false, // Never auto-detect — only from user explicit input
    has_emergency_fund: hasEmergencyFund,
    has_investments: hasInvestments,
    monthly_income: Math.round(monthlyIncome),
    monthly_expense: Math.round(monthlyExpense),
    savings_rate: Math.round(savingsRate * 100) / 100,
  };

  // Upsert profile (overwrite any stale cached data)
  try {
    await serviceClient
      .from('user_financial_profiles')
      .upsert(
        {
          user_id: userId,
          stage: profile.stage,
          has_debts: false,
          has_emergency_fund: profile.has_emergency_fund,
          has_investments: profile.has_investments,
          monthly_income: profile.monthly_income,
          monthly_expense: profile.monthly_expense,
          savings_rate: profile.savings_rate,
          last_stage_check: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'user_id' },
      );
  } catch (err) {
    console.error('Failed to upsert financial profile:', err);
  }

  return profile;
}
