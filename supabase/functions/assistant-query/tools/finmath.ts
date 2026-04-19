/**
 * Pure financial-math tools for the tool-calling agent.
 * No DB access, no async, no external deps — every function is total.
 */

export interface CompoundInterestResult {
  futureValue: number;
  totalContributed: number;
  totalInterest: number;
  schedule: Array<{ year: number; balance: number; contributed: number }>;
}

/// Future value of an account that earns `rate` annually with optional
/// monthly contributions. Used to answer "сколько накоплю под X% за N лет".
/// `rate` is a decimal (0.07 = 7%), not a percentage.
export function compoundInterest(args: {
  principal: number;
  rate: number;
  years: number;
  monthlyContribution?: number;
}): CompoundInterestResult {
  const principal = Math.max(0, args.principal);
  const rate = Math.max(0, args.rate);
  const years = Math.max(0, Math.floor(args.years));
  const monthly = Math.max(0, args.monthlyContribution ?? 0);

  let balance = principal;
  let contributed = principal;
  const monthlyRate = rate / 12;
  const schedule: CompoundInterestResult['schedule'] = [];

  for (let year = 1; year <= years; year++) {
    for (let m = 0; m < 12; m++) {
      balance = balance * (1 + monthlyRate) + monthly;
      contributed += monthly;
    }
    schedule.push({
      year,
      balance: round2(balance),
      contributed: round2(contributed),
    });
  }

  return {
    futureValue: round2(balance),
    totalContributed: round2(contributed),
    totalInterest: round2(balance - contributed),
    schedule,
  };
}

/// Standard amortising-loan monthly payment (PMT). `rate` is annual
/// decimal. Used to answer "сколько платить по кредиту X на Y месяцев
/// под Z%".
export function loanPayment(args: {
  principal: number;
  rate: number;
  termMonths: number;
}): { monthly: number; totalPaid: number; overpay: number } {
  const principal = Math.max(0, args.principal);
  const rate = Math.max(0, args.rate);
  const n = Math.max(1, Math.floor(args.termMonths));

  if (rate === 0) {
    const monthly = principal / n;
    return { monthly: round2(monthly), totalPaid: round2(principal), overpay: 0 };
  }

  const r = rate / 12;
  const monthly = (principal * r * Math.pow(1 + r, n)) / (Math.pow(1 + r, n) - 1);
  const total = monthly * n;
  return {
    monthly: round2(monthly),
    totalPaid: round2(total),
    overpay: round2(total - principal),
  };
}

/// Months of expenses currently covered by liquid savings, plus the gap
/// to the conventional 3 / 6-month emergency fund targets.
export function emergencyFundStatus(args: {
  monthlyExpenses: number;
  currentSavings: number;
}): {
  monthsCovered: number;
  gapToThreeMonths: number;
  gapToSixMonths: number;
  status: 'none' | 'partial' | 'minimum' | 'full' | 'over';
} {
  const expenses = Math.max(0, args.monthlyExpenses);
  const savings = Math.max(0, args.currentSavings);
  if (expenses === 0) {
    return { monthsCovered: 0, gapToThreeMonths: 0, gapToSixMonths: 0, status: 'none' };
  }

  const months = savings / expenses;
  let status: 'none' | 'partial' | 'minimum' | 'full' | 'over';
  if (months <= 0) status = 'none';
  else if (months < 3) status = 'partial';
  else if (months < 6) status = 'minimum';
  else if (months < 12) status = 'full';
  else status = 'over';

  return {
    monthsCovered: round2(months),
    gapToThreeMonths: round2(Math.max(0, expenses * 3 - savings)),
    gapToSixMonths: round2(Math.max(0, expenses * 6 - savings)),
    status,
  };
}

/// Months you can survive at current burn rate. Negative balance returns 0.
export function savingsRunway(args: {
  balance: number;
  monthlyBurn: number;
}): { months: number; days: number } {
  const balance = Math.max(0, args.balance);
  const burn = args.monthlyBurn;
  if (burn <= 0) return { months: Infinity === Infinity ? 9999 : 0, days: 9999 * 30 };
  const months = balance / burn;
  return { months: round2(months), days: Math.round(months * 30) };
}

/// Safe arithmetic evaluator for the `calculator` tool. Accepts only
/// digits, decimal point, parens, and the four operators plus `%`. No
/// `eval`, no functions, no variables — just a Shunting-yard pass.
export function calculator(expression: string): number {
  if (typeof expression !== 'string' || expression.length > 200) {
    throw new Error('expression must be a string ≤ 200 chars');
  }
  // Whitelist: digits, dot, comma, whitespace, parentheses, + - * / %
  if (!/^[\d.,\s()+\-*/%]+$/.test(expression)) {
    throw new Error('expression contains forbidden characters');
  }
  const normalized = expression.replace(/,/g, '.').replace(/\s+/g, '');
  return evalRpn(toRpn(normalized));
}

// ── Shunting-yard helpers (Dijkstra) ─────────────────────────────────

const PRECEDENCE: Record<string, number> = { '+': 1, '-': 1, '*': 2, '/': 2, '%': 2 };

function toRpn(input: string): Array<string | number> {
  const out: Array<string | number> = [];
  const ops: string[] = [];
  let i = 0;
  while (i < input.length) {
    const ch = input[i];
    if (/\d|\./.test(ch)) {
      let j = i;
      while (j < input.length && /[\d.]/.test(input[j])) j++;
      out.push(parseFloat(input.slice(i, j)));
      i = j;
      continue;
    }
    if (ch === '(') { ops.push(ch); i++; continue; }
    if (ch === ')') {
      while (ops.length && ops[ops.length - 1] !== '(') out.push(ops.pop()!);
      if (ops.pop() !== '(') throw new Error('unbalanced parentheses');
      i++;
      continue;
    }
    if (PRECEDENCE[ch] !== undefined) {
      while (
        ops.length
        && ops[ops.length - 1] !== '('
        && PRECEDENCE[ops[ops.length - 1]] >= PRECEDENCE[ch]
      ) {
        out.push(ops.pop()!);
      }
      ops.push(ch);
      i++;
      continue;
    }
    throw new Error(`unexpected character at position ${i}`);
  }
  while (ops.length) {
    const op = ops.pop()!;
    if (op === '(') throw new Error('unbalanced parentheses');
    out.push(op);
  }
  return out;
}

function evalRpn(tokens: Array<string | number>): number {
  const stack: number[] = [];
  for (const t of tokens) {
    if (typeof t === 'number') { stack.push(t); continue; }
    const b = stack.pop();
    const a = stack.pop();
    if (a === undefined || b === undefined) throw new Error('malformed expression');
    switch (t) {
      case '+': stack.push(a + b); break;
      case '-': stack.push(a - b); break;
      case '*': stack.push(a * b); break;
      case '/':
        if (b === 0) throw new Error('division by zero');
        stack.push(a / b);
        break;
      case '%':
        if (b === 0) throw new Error('modulo by zero');
        stack.push(a % b);
        break;
      default: throw new Error(`unknown operator ${t}`);
    }
  }
  if (stack.length !== 1) throw new Error('malformed expression');
  return round4(stack[0]);
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}
