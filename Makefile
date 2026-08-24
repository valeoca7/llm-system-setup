.PHONY: lab-01 lab-01-stop

lab-01:
	$(MAKE) -C labs/01_local-llm-with-rag run

lab-01-stop:
	$(MAKE) -C labs/01_local-llm-with-rag stop
