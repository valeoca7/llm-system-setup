.PHONY: lab-01 lab-01-stop lab-02

lab-01:
	$(MAKE) -C labs/01_local-llm-with-rag run

lab-01-stop:
	$(MAKE) -C labs/01_local-llm-with-rag stop

lab-02:
	@echo "lab-02 (spot GPU LLM node on AWS) is driven by scripts/lab02.sh - see labs/02_spot-gpu-llm-node/README.md"

