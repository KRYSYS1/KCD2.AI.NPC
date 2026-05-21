"""LLM client using OpenAI-compatible API."""

import logging
from openai import AsyncOpenAI

from server.config import LLMConfig

logger = logging.getLogger(__name__)


class LLMClient:
    def __init__(self, config: LLMConfig):
        self.config = config
        self._missing_api_key = self._requires_api_key() and not (config.api_key or "").strip()
        self.client = AsyncOpenAI(
            base_url=config.api_url,
            # The OpenAI SDK raises during construction when api_key is empty.
            # Keep the server/UI alive and report the config problem on use.
            api_key=config.api_key or "missing-api-key",
        )

    def _requires_api_key(self) -> bool:
        api_url = (self.config.api_url or "").lower()
        return "localhost" not in api_url and "127.0.0.1" not in api_url

    async def generate(
        self,
        system_prompt: str,
        messages: list[dict[str, str]],
    ) -> str:
        """Generate a response from the LLM.

        Args:
            system_prompt: The system prompt with NPC context.
            messages: Conversation history as list of {"role": ..., "content": ...}.

        Returns:
            The generated text response.
        """
        if self._missing_api_key:
            raise RuntimeError(
                "LLM API key is not set. Open http://127.0.0.1:4999, enter your Groq/OpenAI API key, "
                "or configure local Ollama in config.json."
            )
        full_messages = [{"role": "system", "content": system_prompt}]
        full_messages.extend(messages)

        try:
            response = await self.client.chat.completions.create(
                model=self.config.model,
                messages=full_messages,
                max_tokens=self.config.max_tokens,
                temperature=self.config.temperature,
            )
            text = response.choices[0].message.content or ""
            return text.strip()
        except Exception as e:
            logger.error(f"LLM request failed: {e}")
            raise
