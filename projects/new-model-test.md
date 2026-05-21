# Llama SEO Content Evaluation Plan — May 2026

## Objective
Evaluate Llama 3.1 (8B) and Llama 3.3 (70B) for generating unique, SEO-optimized long-form content. The goal is to identify a configuration that avoids common "AI-isms" while maintaining high factual density and structural SEO compliance.

## Hardware Context (Arch Workstation)
- **GPU:** RTX 3080 (10GB VRAM) -> Targeted for 8B full offload.
- **CPU/RAM:** Ryzen 5900X / 32GB RAM -> Targeted for 70B partial offload (expect ~2-4 t/s).

## Test Matrix

| Test ID | Model | Quantization | Temp | Repeat Penalty | Objective |
| :--- | :--- | :--- | :--- | :--- | :--- |
| L3-8B-S | llama3.1:8b | Default (Q4) | 0.6 | 1.1 | Baseline SEO (Standard) |
| L3-8B-U | llama3.1:8b | Q6_K | 0.92 | 1.22 | High-Fidelity Unique Prose |
| L3-70B-H | llama3.3:70b | Q4_K_M | 0.7 | 1.15 | High-Authority Content |
| L3-3B-V | llama3.2:3b | Default | 0.8 | 1.1 | Rapid Meta/Micro-copy |

## Evaluation Criteria
1.  **Vocabulary Diversity:** Absence of overused AI transition phrases (e.g., "In conclusion," "It is important to note," "Delve into").
2.  **Instruction Following:** Correct usage of H1-H3 hierarchy and natural keyword integration.
3.  **Topical Depth:** Ability to provide specific "Experience/Expertise" (E-E-A-T) details rather than generic summaries.
4.  **Hardware Efficiency:** Token-per-second vs. quality trade-off for bulk drafting.

## Build Configuration (Modelfile)
Create a test model to iterate on parameters quickly:

```bash
cat <<EOF > Llama-SEO.Modelfile
FROM llama3.1:8b
# Note: Ensure you pull the Q6_K tag specifically if not using default
PARAMETER temperature 0.92
PARAMETER top_p 0.95
PARAMETER repeat_penalty 1.2
SYSTEM """
You are an expert SEO Content Strategist. 
Your goal is to write unique, insightful content that provides value beyond existing top-ranking search results.
RULES:
1. NEVER use the word 'delve', 'landscape', or 'testament'.
2. Use varied sentence structures (burstiness).
3. Prioritize 'Inverted Pyramid' style: most important info first.
4. Avoid corporate jargon; use clear, journalistic prose.
"""
EOF

ollama create llama-seo-8b -f Llama-SEO.Modelfile
```

## Benchmarking Script
```bash
#!/bin/bash
# Usage: ./test-seo.sh "Target Keyword"
KEYWORD=$1
MODELS=("llama-seo-8b" "llama3.3:70b")

for MODEL in "${MODELS[@]}"; do
    echo "--- Testing Model: $MODEL ---"
    time ollama run $MODEL "Write a 500-word blog post introduction and outline for: $KEYWORD. Ensure the tone is unique and authoritative."
    echo -e "\n\n"
done
```

## Next Steps
- [ ] Run `L3-8B-U` vs `L3-70B-H` on the same prompt.
- [ ] Compare output against a "Common AI Words" blacklist.
- [ ] Analyze the speed penalty of running 70B on 32GB system RAM for 2000+ word articles.
- [ ] Integrate the best-performing model into the `jobhunt-app.md` workflow for cover letter tailoring.

## Observations (Log)
*2026-05-21:* Initializing plan. Moving from Qwen to Llama for prose-heavy tasks to test the "Nuance Gap."