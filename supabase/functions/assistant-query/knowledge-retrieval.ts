import type { SupabaseClient } from './types.ts';

interface KnowledgeSection {
  content: string;
  title: string;
  topic: string;
  subtopic: string;
}

/**
 * Retrieve relevant coaching knowledge sections by intent tags and optional user stage.
 * Returns concatenated text (~200-500 tokens) instead of the full knowledge base (~6700 tokens).
 */
export async function retrieveKnowledgeSections(
  client: SupabaseClient,
  intent: string,
  userStage?: string,
  limit = 3,
): Promise<string> {
  try {
    let query = client
      .from('coaching_knowledge_sections')
      .select('content,title,topic,subtopic')
      .contains('intent_tags', [intent])
      .order('priority', { ascending: false })
      .limit(limit);

    // If user stage is known, prefer stage-relevant sections
    if (userStage) {
      query = client
        .from('coaching_knowledge_sections')
        .select('content,title,topic,subtopic')
        .contains('intent_tags', [intent])
        .or(`stage_tags.cs.{${userStage}},stage_tags.cs.{*}`)
        .order('priority', { ascending: false })
        .limit(limit);
    }

    const { data, error } = await query;

    if (error || !data || data.length === 0) {
      // Fallback: try without stage filter
      if (userStage) {
        const { data: fallbackData } = await client
          .from('coaching_knowledge_sections')
          .select('content,title,topic,subtopic')
          .contains('intent_tags', [intent])
          .order('priority', { ascending: false })
          .limit(limit);

        if (fallbackData && fallbackData.length > 0) {
          return formatSections(fallbackData as KnowledgeSection[]);
        }
      }
      return '';
    }

    return formatSections(data as KnowledgeSection[]);
  } catch (err) {
    console.error('retrieveKnowledgeSections error:', err);
    return '';
  }
}

function formatSections(sections: KnowledgeSection[]): string {
  return sections
    .map((s) => `[${s.title}]\n${s.content}`)
    .join('\n\n');
}
