.PHONY: lab-01 lab-01-stop lab-02 lab-02-stop lab-10

lab-01:
	$(MAKE) -C labs/01_local-llm-with-rag run

lab-01-stop:
	$(MAKE) -C labs/01_local-llm-with-rag stop

lab-02:
	$(MAKE) -C labs/02_add-tool-calling run

lab-02-stop:
	$(MAKE) -C labs/02_add-tool-calling stop

lab-10:
	@echo "Lab 10 (spot GPU LLM node on AWS) is documented in labs/10_spot-gpu-llm-node/README.md"

