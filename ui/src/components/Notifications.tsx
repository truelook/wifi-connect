import * as React from 'react';
import { Txt, Alert, Button, Flex, Heading } from 'rendition';

export const Notifications = ({
	hasAvailableNetworks,
	attemptedConnect,
	error,
	onTryAgain,
}: {
	hasAvailableNetworks: boolean;
	attemptedConnect: boolean;
	error: string;
	onTryAgain: () => void;
}) => {
	if (attemptedConnect) {
		return (
			<Flex
				flexDirection="column"
				alignItems="center"
				justifyContent="center"
				px={3}
				py={5}
				style={{
					// Clear phone captive-portal banners that cover the top ~80–120px.
					minHeight: '70vh',
					paddingTop: 'min(20vh, 140px)',
					textAlign: 'center',
				}}
			>
				{error ? (
					<>
						<Heading.h2 mb={3}>Connection failed</Heading.h2>
						<Alert danger m={0} mb={3} style={{ maxWidth: 420, textAlign: 'left' }}>
							<Txt.span>{error}</Txt.span>
						</Alert>
						<Txt color="text.light" mb={4} style={{ maxWidth: 420 }}>
							Check the WiFi password and try again. The setup network will stay
							available until a connection succeeds.
						</Txt>
						<Button primary onClick={onTryAgain}>
							Try again
						</Button>
					</>
				) : (
					<>
						<Heading.h2 mb={3}>Connecting…</Heading.h2>
						<Txt fontSize={2} mb={3} style={{ maxWidth: 420, lineHeight: 1.5 }}>
							Your TrueLook gateway is joining the WiFi network. This page will
							usually close on its own.
						</Txt>
						<Txt color="text.light" style={{ maxWidth: 420, lineHeight: 1.5 }}>
							If it does not connect, the setup network comes back in a few
							minutes — reopen this page to try again. You do not need to press
							Connect again.
						</Txt>
					</>
				)}
			</Flex>
		);
	}

	return (
		<>
			{!hasAvailableNetworks && (
				<Alert m={2} warning>
					<Txt.span>No wifi networks available.&nbsp;</Txt.span>
					<Txt.span>
						Please ensure there is a network within range and reboot the device.
					</Txt.span>
				</Alert>
			)}
			{!!error && (
				<Alert m={2} danger>
					<Txt.span>{error}</Txt.span>
				</Alert>
			)}
		</>
	);
};
