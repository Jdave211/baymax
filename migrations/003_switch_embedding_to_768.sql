-- Migration 003: Switch embedding column from 1536 (OpenAI) to 768 (Cloudflare Workers AI bge-base-en-v1.5)
-- This aligns the schema with the free Cloudflare Workers AI embedding model used by the /embed route.

-- Drop the old column and recreate with the correct dimension.
-- Any existing 1536-dim embeddings are discarded (none were ever generated).
ALTER TABLE public.baymax_logs DROP COLUMN IF EXISTS embedding;
ALTER TABLE public.baymax_logs ADD COLUMN embedding vector(768);

-- Recreate the hybrid search function with the updated vector dimension
CREATE OR REPLACE FUNCTION search_baymax_logs(
  query_text text,
  query_embedding vector(768),
  match_threshold float,
  match_count int
)
RETURNS TABLE (
  id uuid,
  transcript text,
  ai_response text,
  created_at timestamp with time zone,
  similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    baymax_logs.id,
    baymax_logs.transcript,
    baymax_logs.ai_response,
    baymax_logs.created_at,
    1 - (baymax_logs.embedding <=> query_embedding) AS similarity
  FROM baymax_logs
  WHERE 
    (baymax_logs.transcript ILIKE '%' || query_text || '%' OR baymax_logs.ai_response ILIKE '%' || query_text || '%')
    AND baymax_logs.embedding IS NOT NULL
    AND 1 - (baymax_logs.embedding <=> query_embedding) > match_threshold
  ORDER BY similarity DESC
  LIMIT match_count;
END;
$$;
