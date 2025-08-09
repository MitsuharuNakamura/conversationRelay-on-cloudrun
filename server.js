import express from 'express';
import http from 'http';
import { WebSocketServer } from 'ws';
import twilio from 'twilio';
import dotenv from 'dotenv';
import OpenAI from 'openai';

dotenv.config();

const app = express();
app.use(express.urlencoded({ extended: false }));
app.use(express.json());

const PORT = process.env.PORT || 8080;
const WS_PATH = process.env.WS_PATH || '/relay';
const CR_LANGUAGE = process.env.CR_LANGUAGE || 'ja-JP';
const CR_TTS_PROVIDER = process.env.CR_TTS_PROVIDER || 'Google';
const CR_VOICE = process.env.CR_VOICE || 'ja-JP-Standard-B';
const CR_WELCOME = process.env.CR_WELCOME || 'もしもし。こんにちは。こちらはAIオペレーターです。なんでもご相談ください。';
const WSS_URL = process.env.WSS_URL;
const WEBHOOK_VALIDATE = process.env.WEBHOOK_VALIDATE === 'true';
const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || 'あなたは親切で丁寧な日本語の電話オペレーターです。簡潔で自然な会話を心がけてください。';

const openai = OPENAI_API_KEY ? new OpenAI({ apiKey: OPENAI_API_KEY }) : null;

const server = http.createServer(app);

const wss = new WebSocketServer({ 
  server, 
  path: WS_PATH,
  clientTracking: true 
});

const KEEPALIVE_INTERVAL = 25000;
const activeConnections = new Map();
const conversationSessions = new Map();

function validateTwilioRequest(req, res, next) {
  if (!WEBHOOK_VALIDATE) {
    return next();
  }

  if (!TWILIO_AUTH_TOKEN) {
    console.error('TWILIO_AUTH_TOKEN is required when WEBHOOK_VALIDATE is enabled');
    return res.status(500).send('Server misconfiguration');
  }

  const signature = req.get('X-Twilio-Signature');
  if (!signature) {
    return res.status(403).send('Missing signature');
  }

//  const protocol = req.get('x-forwarded-proto') || req.protocol;
  const host = req.get('host');
  const url = `wss://${host}${req.originalUrl}`;
  
  const params = req.body || {};
  
  const isValid = twilio.validateRequest(
    TWILIO_AUTH_TOKEN,
    signature,
    url,
    params
  );

  if (!isValid) {
    console.error('Invalid Twilio signature', { url, signature });
    return res.status(403).send('Invalid signature');
  }

  next();
}

app.get('/healthz', (req, res) => {
  res.status(200).json({ 
    status: 'healthy',
    wsConnections: activeConnections.size,
    timestamp: new Date().toISOString()
  });
});

app.all('/twiml/:preset', validateTwilioRequest, (req, res) => {
  const { preset } = req.params;
  const VoiceResponse = twilio.twiml.VoiceResponse;
  
  const response = new VoiceResponse();
  
  let wsUrl = WSS_URL;
  if (!wsUrl) {
    // Auto-generate WebSocket URL based on request headers
    const protocol = req.get('x-forwarded-proto') === 'https' ? 'wss' : 'ws';
    const host = req.get('host');
    wsUrl = `${protocol}://${host}${WS_PATH}`;
  }
  
  const connect = response.connect();
  const conversationRelay = connect.conversationRelay({
    url: wsUrl,
    language: CR_LANGUAGE,
    ttsProvider: CR_TTS_PROVIDER,
    voice: CR_VOICE,
    welcomeGreeting: CR_WELCOME,
    interruptible: true,
    transcriptionProvider: 'Google',
    speechModel: 'telephony',
    profanityFilter: false
  });
  
  conversationRelay.parameter({ name: 'preset', value: preset });
  conversationRelay.parameter({ name: 'callSid', value: req.body?.CallSid || 'unknown' });
  
  res.type('text/xml');
  res.send(response.toString());
  
  console.log(`TwiML generated for preset: ${preset}, WebSocket URL: ${wsUrl}`);
});

wss.on('connection', (ws, req) => {
  const connectionId = Math.random().toString(36).substring(7);
  console.log(`WebSocket connection established: ${connectionId}`);
  
  const keepaliveTimer = setInterval(() => {
    if (ws.readyState === ws.OPEN) {
      ws.ping();
    }
  }, KEEPALIVE_INTERVAL);
  
  activeConnections.set(connectionId, {
    ws,
    keepaliveTimer
  });
  
  conversationSessions.set(connectionId, {
    history: [
      {
        role: 'system',
        content: SYSTEM_PROMPT
      }
    ],
    isProcessing: false
  });
  
  ws.on('pong', () => {
    // Keepalive pong received - connection is alive
  });
  
  ws.on('message', async (data) => {
    try {
      const message = JSON.parse(data.toString());
      console.log(`Message received on ${connectionId}:`, message.type);
      
      await handleRelayMessage(ws, message, connectionId);
    } catch (error) {
      console.error(`Error processing message on ${connectionId}:`, error);
    }
  });
  
  ws.on('close', (code, reason) => {
    console.log(`WebSocket connection closed: ${connectionId}, code: ${code}, reason: ${reason}`);
    
    const connection = activeConnections.get(connectionId);
    if (connection) {
      clearInterval(connection.keepaliveTimer);
      activeConnections.delete(connectionId);
    }
    conversationSessions.delete(connectionId);
  });
  
  ws.on('error', (error) => {
    console.error(`WebSocket error on ${connectionId}:`, error);
  });
});

async function handleRelayMessage(ws, message, connectionId) {
  const { type } = message;
  
  console.log(`Message received on ${connectionId}:`, JSON.stringify(message).substring(0, 200));
  
  if (type === 'prompt') {
    const question = message.voicePrompt;
    
    if (question) {
      console.log(`User said on ${connectionId}: ${question}`);
      
      const session = conversationSessions.get(connectionId);
      if (session && !session.isProcessing) {
        session.isProcessing = true;
        await processAIResponse(ws, question, connectionId);
        session.isProcessing = false;
      }
    } else {
      console.log(`No voicePrompt found in message:`, message);
    }
  } else if (type === 'interrupt') {
    console.log(`Interrupt on ${connectionId}`);
    const interruptSession = conversationSessions.get(connectionId);
    if (interruptSession) {
      interruptSession.isProcessing = false;
    }
  } else {
    console.log(`Unhandled message type on ${connectionId}: ${type}`);
  }
}

async function processAIResponse(ws, question, connectionId) {
  const session = conversationSessions.get(connectionId);
  
  if (!session) {
    console.error(`Session not found for ${connectionId}`);
    return;
  }
  
  if (!question) {
    ws.send(JSON.stringify({
      type: 'text',
      token: '申し訳ございません、聞き取れませんでした。もう一度お願いします。',
      last: true
    }));
    return;
  }
  
  console.log('User question:', question);
  
  session.history.push({
    role: 'user',
    content: question
  });
  
  if (!openai) {
    console.log('OpenAI not configured, using placeholder response');
    const placeholderResponse = `あなたのメッセージ「${question}」を受け取りました。これはプレースホルダーのレスポンスです。`;
    session.history.push({
      role: 'assistant',
      content: placeholderResponse
    });
    ws.send(JSON.stringify({
      type: 'text',
      token: placeholderResponse,
      last: true
    }));
    return;
  }
  
  try {
    const stream = await openai.chat.completions.create({
      model: 'gpt-4o-mini',
      messages: session.history,
      stream: true,
      temperature: 0.7,
      max_tokens: 500
    });
    
    let fullResponse = '';
    let buffer = '';
    const sentenceDelimiterRegex = /[。！？]/;
    
    for await (const chunk of stream) {
      if (!session.isProcessing) {
        console.log(`Processing interrupted for ${connectionId}`);
        break;
      }
      
      const content = chunk.choices[0]?.delta?.content;
      if (content) {
        buffer += content;
        fullResponse += content;
        
        let sentences = buffer.split(sentenceDelimiterRegex);
        
        while (sentences.length > 1) {
          const sentence = sentences.shift();
          if (sentence) {
            const delimiter = buffer.charAt(sentence.length);
            const textToSend = sentence + (sentenceDelimiterRegex.test(delimiter) ? delimiter : '');
            
            ws.send(JSON.stringify({
              type: 'text',
              token: textToSend
            }));
            
            buffer = buffer.substring(textToSend.length);
          }
        }
      }
    }
    
    // Send final message with last: true flag
    if (session.isProcessing) {
      ws.send(JSON.stringify({
        type: 'text',
        token: buffer || '',
        last: true
      }));
    }
    
    if (fullResponse) {
      session.history.push({
        role: 'assistant',
        content: fullResponse
      });
      console.log('AI response:', fullResponse);
    }
    
    if (session.history.length > 20) {
      session.history = [
        session.history[0],
        ...session.history.slice(-10)
      ];
    }
    
  } catch (error) {
    console.error('OpenAI API error:', error);
    ws.send(JSON.stringify({
      type: 'text',
      token: '申し訳ございません、システムエラーが発生しました。しばらくお待ちください。',
      last: true
    }));
  }
}

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`WebSocket path: ${WS_PATH}`);
  console.log(`Health check: http://localhost:${PORT}/healthz`);
  console.log(`TwiML endpoint: http://localhost:${PORT}/twiml/:preset`);
  console.log(`Webhook validation: ${WEBHOOK_VALIDATE}`);
  console.log(`OpenAI configured: ${!!openai}`);
});