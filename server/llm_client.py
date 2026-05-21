"""LLM client using OpenAI-compatible API."""

import logging
from openai import AsyncOpenAI

from server.config import LLMConfig

logger = logging.getLogger(__name__)


class LLMClient:
    def __init__(self, config: LLMConfig):
        self.config = config
        self.client = AsyncOpenAI(
            base_url=config.api_url,
            api_key=config.api_key,
        )

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
