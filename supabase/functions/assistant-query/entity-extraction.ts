import { normalizeForMatch } from './utils.ts';
import type { CategoryRow, CreateTxEntities } from './types.ts';

// Currency words that should NOT be treated as category hints
const CURRENCY_WORDS = new Set([
  'рублей', 'руб', 'рубль', 'рубля', 'р',
  'долларов', 'доллар', 'доллара', 'баксов', 'бакс',
  'евро',
  'донгов', 'донг', 'донга',
  'батов', 'бат', 'бата',
  'рупий', 'рупия', 'рупию',
  'тысяч', 'тыс', 'тысячи', 'тысячу',
  'миллион', 'миллиона', 'миллионов', 'млн',
]);

// Maps Russian currency words to ISO codes for text-based currency detection
export const CURRENCY_WORD_MAP: Record<string, string> = {
  'рублей': 'RUB', 'руб': 'RUB', 'рубль': 'RUB', 'рубля': 'RUB',
  'долларов': 'USD', 'доллар': 'USD', 'доллара': 'USD', 'баксов': 'USD', 'бакс': 'USD',
  'евро': 'EUR',
  'донгов': 'VND', 'донг': 'VND', 'донга': 'VND',
  'батов': 'THB', 'бат': 'THB', 'бата': 'THB',
  'рупий': 'IDR', 'рупия': 'IDR', 'рупию': 'IDR',
};

// Synonym mapping for common Russian expense descriptions -> category names
export const CATEGORY_SYNONYMS: Record<string, string[]> = {
  'еда': ['обед', 'ужин', 'завтрак', 'продукты', 'еда', 'перекус', 'снеки', 'мясо', 'молоко', 'хлеб', 'фрукты', 'овощи', 'бакалея'],
  'транспорт': ['такси', 'метро', 'автобус', 'трамвай', 'бензин', 'топливо', 'парковка', 'каршеринг', 'проезд', 'транспорт', 'электричка', 'поезд'],
  'кафе': ['кофе', 'кафе', 'ресторан', 'бар', 'столовая', 'фастфуд', 'пицца', 'суши', 'доставка еды'],
  'развлечения': ['кино', 'театр', 'концерт', 'развлечения', 'игры', 'клуб', 'боулинг', 'бильярд'],
  'здоровье': ['аптека', 'лекарства', 'врач', 'клиника', 'медицина', 'анализы', 'стоматолог', 'здоровье'],
  'одежда': ['одежда', 'обувь', 'джинсы', 'куртка', 'платье', 'футболка', 'кроссовки', 'шмотки'],
  'связь': ['телефон', 'интернет', 'связь', 'мобильный', 'подписка', 'сотовый'],
  'жилье': ['аренда', 'квартплата', 'коммуналка', 'жкх', 'ипотека', 'ремонт'],
  'образование': ['курсы', 'книги', 'обучение', 'учеба', 'образование', 'школа', 'репетитор'],
  'красота': ['парикмахер', 'стрижка', 'маникюр', 'косметика', 'салон', 'красота'],
  'спорт': ['спортзал', 'фитнес', 'тренировка', 'бассейн', 'спорт', 'йога'],
  'подарки': ['подарок', 'подарки', 'цветы', 'сувенир'],
  // Income synonyms
  'зарплата': ['зарплата', 'зп', 'оклад', 'аванс', 'жалование'],
  'подработка': ['подработка', 'фриланс', 'халтура', 'шабашка'],
};

export function extractCreateTxEntities(query: string): CreateTxEntities {
  const normalized = normalizeForMatch(query);

  // Extract amount: first number (supports "1 500", "1500.50", "1500,50")
  const amountMatch = normalized.match(/(\d[\d\s]*[\d](?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)/);
  let amount: number | null = null;
  if (amountMatch) {
    const raw = amountMatch[1].replace(/\s/g, '').replace(',', '.');
    const parsed = parseFloat(raw);
    if (Number.isFinite(parsed) && parsed > 0) {
      amount = parsed;
    }
  }

  // Detect currency from text
  let currency: string | null = null;
  const words = normalized.split(/\s+/);
  for (const word of words) {
    if (CURRENCY_WORD_MAP[word]) {
      currency = CURRENCY_WORD_MAP[word];
      break;
    }
  }

  // Determine transaction type
  const isIncome = /(доход|зарплат|получил|получила|заработ|премия|перевод\s*мне|возврат)/u.test(normalized);
  const tx_type: 'income' | 'expense' = isIncome ? 'income' : 'expense';

  // Stop words: period words + currency words + prepositions
  const STOP = new Set([
    ...CURRENCY_WORDS,
    'неделю', 'месяц', 'сегодня', 'вчера', 'завтра', 'время', 'день', 'период',
    'на', 'за',
  ]);

  // Extract category hint: text after "на/за" preposition
  let category_hint: string | null = null;
  const prepositionMatch = normalized.match(/(?:на|за)\s+([а-яё]{2,30})(?:\s|$)/u);
  if (prepositionMatch?.[1]) {
    const candidate = prepositionMatch[1];
    if (!STOP.has(candidate)) {
      category_hint = candidate;
    }
  }

  // If no preposition match, try to find category hint near the amount
  if (!category_hint) {
    const wordsAfterAmount = normalized.match(/\d[\d\s.,]*\s+([а-яё]{2,30})(?:\s|$)/u);
    if (wordsAfterAmount?.[1]) {
      const candidate = wordsAfterAmount[1];
      if (!STOP.has(candidate)) {
        category_hint = candidate;
      }
    }
  }

  return {
    amount,
    tx_type,
    category_hint,
    description: query.trim(),
    currency,
  };
}

export function fuzzyMatchCategory(
  hint: string,
  categories: CategoryRow[],
  txType: 'income' | 'expense' = 'expense',
): CategoryRow | null {
  if (!hint) return null;
  const hintLower = normalizeForMatch(hint);

  // Filter categories by transaction type
  const filtered = categories.filter((cat) => !cat.type || cat.type === txType);

  // 1. Exact match on normalized names
  for (const cat of filtered) {
    if (normalizeForMatch(cat.name) === hintLower) return cat;
  }

  // 2. Substring: category name contains hint or hint contains category name
  for (const cat of filtered) {
    const catLower = normalizeForMatch(cat.name);
    if (catLower.includes(hintLower) || hintLower.includes(catLower)) return cat;
  }

  // 3. Synonym mapping
  for (const [canonicalName, synonyms] of Object.entries(CATEGORY_SYNONYMS)) {
    if (synonyms.some((s) => hintLower.includes(s) || s.includes(hintLower))) {
      for (const cat of filtered) {
        if (normalizeForMatch(cat.name).includes(canonicalName)) return cat;
      }
    }
  }

  return null;
}
